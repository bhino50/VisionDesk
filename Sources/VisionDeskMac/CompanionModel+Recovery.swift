import Foundation
import DeskCore

extension CompanionModel {
    /// Ends a session whose capture stopped or could not start, retrying only when that can help.
    func captureEnded(_ failure: CaptureFailure, while action: String = "Capture stopped") {
        switch failure.disposition {
        case .retry:
            recoverRemote(after: "\(action): \(failure.reason)")
        case .stoppedByOwner:
            // The macOS screen-sharing controls are the owner's own stop. Restarting capture on
            // our own would override that choice, so this ends sharing exactly as Stop Sharing does.
            stop(headsetNotice: HeadsetNotice.stoppedFromMacControls)
            status = "Screen sharing was stopped from the macOS screen-sharing controls. Start sharing again when you are ready."
        case .notPermitted:
            // Nothing in-process can grant this, so a retry would only repeat the refusal.
            stop(headsetNotice: HeadsetNotice.recordingNotAllowed)
            screenPermission = false
            status = "Screen recording is not allowed for VisionDeskMac. Allow it in Privacy & Security → Screen & System Audio Recording, then start sharing again."
        case .invalidGeometry:
            let explanation = "\(failure.reason) Change the display resolution or arrangement, then start sharing again."
            stop(headsetNotice: explanation)
            status = explanation
        case .unsupportedArrangement:
            // Starting again cannot succeed until the arrangement changes, so nothing is retried
            // and the Mac is not kept awake. A remote host refuses automatic starts while it
            // lasts (`resumeRemote`), and the self-heal check resumes it once it is over; a local
            // session waits for the owner.
            let remote = persistentHostingRequested
            resumeTask?.cancel(); resumeTask = nil
            // The wait ends any failing run, so the resume it leads to is prompt and gets a full
            // keep-awake window.
            backoff.reset()
            stop(manual: !remote, headsetNotice: HeadsetNotice.tooManyDisplays(resumes: remote))
            status = remote ? DisplayLimitExceeded.remoteStatus : failure.reason
        }
    }

    /// Answers `didChangeScreenParametersNotification`, which is coarse: a session restarts only
    /// when the inventory it was built from — display identity, pixel size and point geometry —
    /// actually changed. Restarting for anything else dropped a connected headset and rebuilt
    /// every capture for a screen arrangement that was still right.
    func displayConfigurationChanged() {
        guard sharing || busy else {
            refreshInventory()
            // A host waiting for fewer displays resumes as soon as one is unplugged rather than at
            // the next self-heal look. `resumeRemote` still refuses a paused or stopped host.
            if autoRecoveryArmed, resumeTask == nil { resumeRemote() }
            return
        }
        refreshInventory()
        let arrangement = displays
        guard arrangement != sessionInventory else { return }
        let remote = persistentHostingRequested
        stop(manual: false, retainKeepAwake: remote, headsetNotice: HeadsetNotice.displaysChanged(resumes: remote))
        guard remote else {
            status = "Display arrangement changed. Start sharing again to refresh all screens."
            return
        }
        guard resumeRemote() == nil else {
            status = "Selected displays changed. Restarting sharing."
            return
        }
        // Paused by the session rather than scheduled, so nothing is recovering to stay awake for.
        keepAwake.release()
        status = Self.pausedStatus
    }

    /// Restarts an unattended remote host that is idle but should be sharing.
    ///
    /// Notifications stay the fast path. This is the backstop for one that never arrived — an
    /// unlock seen before the session reported it, a lost wake notice — which used to leave
    /// sharing paused until someone came to the Mac. It never overrides the owner: a manual stop,
    /// a terminal failure, a restart already scheduled, or remote hosting never having been
    /// started all leave it alone, and the live session must report this Mac on the console and
    /// unlocked with its displays awake before anything is scheduled. Its first look after a
    /// pause comes a full interval later (`suspendRemote`), and a pause notice outranks the live
    /// session for its grace window (`HostSessionFlags`), because macOS can lag the notice.
    func selfHealRemoteHosting(now: TimeInterval? = nil) {
        let now = now ?? uptime()
        guard persistentHostingRequested, remoteHostingRequested, !manuallyStopped, !sharing, !busy,
              resumeTask == nil, now - lastSelfHealUptime >= Self.selfHealInterval else { return }
        lastSelfHealUptime = now
        hostSession = hostSession.reconciled(with: liveSession(), at: now)
        resumeRemote()
    }

    /// Applies one session notification. Internal so the behavior harness can deliver one
    /// without posting a notification outside its own process.
    func receiveSessionNotice(_ notice: HostSessionNotice) {
        let now = uptime()
        hostSession.apply(notice, at: now)
        if notice.pausesSharing { suspendRemote(at: now, by: notice) } else { resumeRemote() }
    }

    func suspendRemote(at now: TimeInterval, by notice: HostSessionNotice) {
        remoteSuspended = true
        // A pending restart would only find the session paused; the wake or unlock reschedules it.
        resumeTask?.cancel(); resumeTask = nil
        // Suspension is not a failure, so the resume that follows it should be prompt.
        backoff.reset()
        // The backstop is for a notice that never arrives, so its first look comes a full interval
        // after the pause, never on the next watchdog tick while macOS may still lag the notice.
        lastSelfHealUptime = now
        stop(manual: false, headsetNotice: HeadsetNotice.paused(by: notice, resumes: persistentHostingRequested))
        if persistentHostingRequested { status = Self.pausedStatus }
    }

    /// Schedules an automatic start and returns its delay, or nil when nothing was scheduled.
    @discardableResult
    func resumeRemote() -> Int? {
        guard !hostSession.blocksResume, hostSessionAvailable else { return nil }
        remoteSuspended = false
        guard persistentHostingRequested, !manuallyStopped else { return nil }
        // Wait without retrying capture when none of the selected physical screens
        // are available. Inventory notifications and self-heal re-resolve their UUIDs.
        guard arrangementSupported else {
            if status == Self.pausedStatus || status == Self.pausedUntilUnlockedStatus {
                status = displaySelectionUnavailableStatus
            }
            return nil
        }
        resumeTask?.cancel()
        let delay = backoff.delaySeconds
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.resumeTask = nil
            guard !self.remoteSuspended, !self.manuallyStopped else { return }
            self.start(allowControl: self.reconnectControlAllowed, resetControlPause: false)
        }
        return delay
    }

    var hostSessionAvailable: Bool { liveSession().isAvailable }
    var arrangementSupported: Bool {
        let inventory = inventoryProvider()
        let selection = resolveDisplaySelection?(inventory) ?? selectedDisplayIDs
        return !DisplayCapturePlan.select(inventory: inventory, preferredIDs: selection).isEmpty
    }

    func recoverRemote(after reason: String) {
        let retry = persistentHostingRequested && !manuallyStopped
        let now = uptime()
        if retry { backoff.recordFailure(at: now) }
        // Restarts keep the Mac awake only inside the recovery window. Past it they continue
        // without the hold, so a failure that never clears cannot keep the Mac awake forever.
        let holdAwake = retry && remoteConfiguration.enabled && backoff.keepsAwake(at: now)
        stop(manual: !retry, retainKeepAwake: holdAwake, headsetNotice: retry ? HeadsetNotice.restarting : HeadsetNotice.stopped)
        guard retry else { status = reason; return }
        guard let delay = resumeRemote() else {
            // Paused by the session rather than scheduled, so nothing is recovering to stay awake for.
            keepAwake.release()
            status = arrangementSupported ? reason : displaySelectionUnavailableStatus
            return
        }
        status = RemoteRecoveryBackoff.status(reason, retryingIn: delay,
                                              keepingAwake: holdAwake || !remoteConfiguration.keepAwake)
    }

}
