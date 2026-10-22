import AppKit
import DeskCore
import DeskTransport
import Foundation
import ScreenCaptureKit

/// Unattended recovery of the production `CompanionModel`. Every remote model here injects its
/// pairing-key loader, live-session observation and keep-awake hold, so no check reads the real
/// Keychain, creates a power assertion, or posts a notification outside this process.
@MainActor
func runHostRecoveryChecks(_ runner: CheckRunner) async {
    let key = PairingKey.generate()
    let available = HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false)

    await runner.check("ScreenCaptureKit stops are classified by whether retrying can help") {
        runner.expectEqual(CaptureFailure(SCStreamError(.userStopped)).disposition, .stoppedByOwner, "the macOS screen-sharing controls")
        runner.expectEqual(CaptureFailure(SCStreamError(.userDeclined)).disposition, .notPermitted, "a refused recording permission")
        runner.expectEqual(CaptureFailure(SCStreamError(.missingEntitlements)).disposition, .notPermitted, "a missing entitlement")
        // systemStoppedStream (-3821), noCaptureSource, a dropped capture-service connection, internal.
        for code in [-3821, -3815, -3805, -3811] {
            let failure = CaptureFailure(NSError(domain: SCStreamErrorDomain, code: code))
            runner.expectEqual(failure.disposition, .retry, "ScreenCaptureKit code \(code) is worth retrying")
        }
        let otherDomain = NSError(domain: NSOSStatusErrorDomain, code: SCStreamError.Code.userStopped.rawValue)
        runner.expectEqual(CaptureFailure(otherDomain).disposition, .retry, "the code only counts in its own domain")
        runner.expectEqual(CaptureFailure(CheckError.preparationAbandoned).disposition, .retry, "unrelated errors keep retrying")
        runner.expectEqual(CaptureFailure(retryable: "encoder").disposition, .retry, "an encoder failure retries")
        let tooMany = CaptureFailure(DisplayLimitExceeded(count: 5))
        runner.expectEqual(tooMany.disposition, .unsupportedArrangement, "more displays than a session carries is not retried")
        runner.expect(tooMany.reason.contains("up to four displays"), "and keeps its explanation, got: \(tooMany.reason)")
        runner.expectEqual(CaptureFailure(NSError(domain: "VisionDesk", code: 2)).disposition, .retry, "other companion errors keep retrying")
    }

    await runner.check("A stop from the macOS screen-sharing controls is final, even for an unattended host") {
        var loads = 0
        let recorder = KeepAwakeRecorder()
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { loads += 1; return key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   liveSession: { available }, keepAwake: recorder.hold)
        model.start()
        recorder.hold.hold()
        model.captureEnded(CaptureFailure(SCStreamError(.userStopped)))
        gate.release()
        await drainMainActor()
        runner.expect(!model.busy && !model.sharing && !model.restartPending, "sharing ends with nothing scheduled")
        runner.expect(model.status.contains("macOS screen-sharing controls"), "the status names the owner's stop, got: \(model.status)")
        runner.expect(!recorder.hold.isHeld, "the Mac is allowed to sleep again")
        try? await Task.sleep(nanoseconds: 2_300_000_000)
        model.selfHealRemoteHosting(now: ProcessInfo.processInfo.systemUptime + 100)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        runner.expectEqual(loads, 1, "neither the retry path nor the self-heal backstop restarts it")
        model.stop()
    }

    await runner.check("A refused recording permission stops retrying and says what to allow") {
        var loads = 0
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { loads += 1; return key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { throw SCStreamError(.userDeclined) }, liveSession: { available },
                                   keepAwake: KeepAwakeRecorder().hold)
        model.screenPermission = true
        model.start()
        await drainMainActor()
        runner.expect(!model.busy && !model.sharing && !model.restartPending, "the host stops instead of scheduling a retry")
        runner.expect(!model.screenPermission, "the setup panel asks for the permission again")
        runner.expect(model.status.contains("Screen & System Audio Recording"), "the status says where to allow it, got: \(model.status)")
        try? await Task.sleep(nanoseconds: 2_400_000_000)
        runner.expectEqual(loads, 1, "no retry loop re-reads the key")
        model.stop()
    }

    await runner.check("An interrupted capture retries on its own and keeps the unattended Mac awake meanwhile") {
        var loads = 0
        let recorder = KeepAwakeRecorder()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { loads += 1; return key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { throw CheckError.preparationAbandoned }, liveSession: { available },
                                   keepAwake: recorder.hold)
        recorder.hold.hold()
        model.sharing = true
        model.captureEnded(CaptureFailure(NSError(domain: SCStreamErrorDomain, code: -3821)))
        runner.expect(recorder.hold.isHeld, "tearing capture down to rebuild it keeps the hold")
        runner.expect(model.restartPending, "a restart is scheduled")
        runner.expect(model.status.hasSuffix("Retrying in 2 s."), "the status says when, got: \(model.status)")
        await waitUntil(seconds: 4) { loads >= 1 }
        runner.expect(loads >= 1, "the host tried again without anyone at the Mac")
        runner.expect(recorder.hold.isHeld && recorder.ends == 0, "never released while recovering")
        model.stop()
        runner.expect(!recorder.hold.isHeld && recorder.ends == 1, "a manual stop releases it exactly once")
        runner.expect(!model.restartPending, "and cancels the pending restart")
    }

    await runner.check("Lock, sleep and session changes still release the keep-awake hold") {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let recorder = KeepAwakeRecorder()
            let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { key },
                                       saveRemoteConfiguration: { _ in },
                                       contentProvider: { throw CheckError.preparationAbandoned }, liveSession: { available },
                                       keepAwake: recorder.hold)
            recorder.hold.hold()
            model.sharing = true
            NSWorkspace.shared.notificationCenter.post(name: name, object: nil)
            await drainMainActor(rounds: 2)
            runner.expect(!recorder.hold.isHeld, "\(name.rawValue) gives the hold up")
            runner.expect(!model.restartPending, "\(name.rawValue) schedules nothing while suspended")
            model.stop()
        }
    }

    await runner.check("A display notification that leaves the inventory unchanged keeps the session") {
        var inventory = [syntheticDisplay(1), syntheticDisplay(2)]
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, saveRemoteConfiguration: { _ in }, contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { inventory })
        model.start()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drainMainActor(rounds: 2)
        runner.expect(model.busy, "an unchanged inventory leaves the session running")
        // Preparation that was left alone reaches its own outcome; an abandoned one stays quiet.
        gate.release()
        await drainMainActor()
        runner.expect(model.status.hasPrefix("Could not start sharing"), "the original session continued, got: \(model.status)")

        let second = PreparationGate()
        let restarted = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, saveRemoteConfiguration: { _ in }, contentProvider: { await second.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                       inventory: { inventory })
        restarted.start()
        inventory[1] = syntheticDisplay(2, pointWidth: 1_280)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drainMainActor(rounds: 2)
        runner.expect(!restarted.busy && !restarted.sharing, "a real geometry change still stops the session")
        runner.expectEqual(restarted.status, "Selected displays changed. Restarting sharing.", "local wording")
        second.release()
        await drainMainActor()
        runner.expectEqual(restarted.status, "Selected displays changed. Restarting sharing.", "abandoned quietly")
        model.stop(); restarted.stop()
    }

    await runner.check("A real display change restarts an unattended host without letting it sleep") {
        var inventory = [syntheticDisplay(1)]
        var loads = 0
        let recorder = KeepAwakeRecorder()
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { loads += 1; return key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { inventory }, liveSession: { available }, keepAwake: recorder.hold)
        model.start()
        recorder.hold.hold()
        inventory.append(syntheticDisplay(2))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drainMainActor(rounds: 2)
        runner.expect(!model.busy, "the old session is torn down")
        runner.expect(recorder.hold.isHeld, "the hold survives the rebuild")
        runner.expectEqual(model.status, "Selected displays changed. Restarting sharing.", "remote wording")
        gate.release()
        await waitUntil(seconds: 3) { loads >= 2 }
        runner.expect(loads >= 2, "sharing restarts by itself")
        model.stop()
        runner.expect(!recorder.hold.isHeld, "the owner's stop releases the hold")
    }

    await runner.check("A missed session notification no longer strands an unattended host") {
        var observed = available
        var loads = 0
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { loads += 1; return key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   liveSession: { observed }, keepAwake: KeepAwakeRecorder().hold)
        model.start()
        observed.screenLocked = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        await drainMainActor(rounds: 2)
        gate.release()
        // The matching sessionDidBecomeActiveNotification never arrives.
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        runner.expectEqual(loads, 1, "while macOS reports the Mac locked, the backstop resumes nothing")
        observed.screenLocked = false
        model.selfHealRemoteHosting(now: ProcessInfo.processInfo.systemUptime + 100)
        await waitUntil(seconds: 3) { loads >= 2 }
        runner.expect(loads >= 2, "once the live session is available the host resumes on its own")
        model.stop()
        model.selfHealRemoteHosting(now: ProcessInfo.processInfo.systemUptime + 200)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        runner.expect(!model.busy && !model.restartPending, "a manual stop is never overridden")
    }

    await runner.check("An unanswered sleep notice expires only after enough awake time") {
        var loads = 0
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { loads += 1; return key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   liveSession: { available }, keepAwake: KeepAwakeRecorder().hold)
        model.start()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        let notice = ProcessInfo.processInfo.systemUptime
        await drainMainActor(rounds: 2)
        gate.release()
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        runner.expectEqual(loads, 1, "a recent sleep notice still pauses sharing")
        model.selfHealRemoteHosting(now: notice + HostSessionFlags.noticeGraceSeconds + 20)
        await waitUntil(seconds: 3) { loads >= 2 }
        runner.expect(loads >= 2, "a sleep notice unanswered for that much awake time no longer blocks sharing")
        model.stop()
    }

    await runner.check("Session flags reconcile lock, console and display state against macOS") {
        var flags = HostSessionFlags(locked: true, sessionInactive: true, screensAsleep: true, sleepNoticeUptime: 100)
        let live = HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false)
        let early = flags.reconciled(with: live, at: 100 + HostSessionFlags.noticeGraceSeconds - 1)
        runner.expect(!early.locked && !early.sessionInactive && !early.screensAsleep, "live state replaces flags no pause notice set")
        runner.expect(early.sleeping && early.blocksResume, "a recent sleep notice still blocks")
        let late = flags.reconciled(with: live, at: 100 + HostSessionFlags.noticeGraceSeconds)
        runner.expect(!late.sleeping && !late.blocksResume, "an expired sleep notice no longer blocks")
        flags.sleepNoticeUptime = nil
        let locked = flags.reconciled(with: HostSessionObservation(onConsole: false, screenLocked: true, displaysAsleep: true), at: 0)
        runner.expect(locked.locked && locked.sessionInactive && locked.screensAsleep, "a live lock, switch-out or sleeping display blocks")
    }

    await runner.check("A pause notice outranks the live session only for its grace window") {
        let awake = HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false)
        let grace = HostSessionFlags.noticeGraceSeconds
        for notice in HostSessionNotice.allCases where notice.pausesSharing {
            var flags = HostSessionFlags()
            flags.apply(notice, at: 100)
            runner.expect(flags.blocksResume, "\(notice) pauses sharing")
            runner.expect(flags.reconciled(with: awake, at: 100 + grace - 1).blocksResume,
                          "\(notice) still blocks while macOS may not report it yet")
            runner.expect(!flags.reconciled(with: awake, at: 100 + grace).blocksResume,
                          "past the window an unanswered \(notice) is presumed lost")
        }
        let answers: [(HostSessionNotice, HostSessionNotice)] = [(.locked, .unlocked), (.willSleep, .didWake),
                                                                 (.screensSlept, .screensWoke), (.sessionResigned, .sessionActivated)]
        for (pause, answer) in answers {
            var flags = HostSessionFlags()
            flags.apply(pause, at: 100)
            flags.apply(answer, at: 101)
            runner.expect(!flags.blocksResume, "\(answer) answers \(pause) without waiting for the window")
        }
        var paused = HostSessionFlags()
        paused.apply(.screensSlept, at: 100)
        let liveLock = paused.reconciled(with: HostSessionObservation(onConsole: true, screenLocked: true, displaysAsleep: false), at: 101)
        runner.expect(liveLock.locked, "inside the window a live lock is still honored at once")
    }

    await runner.check("A lock notice outranks a live session that has not reported the lock yet") {
        let clock = ManualClock()
        var observed = available  // macOS has not set CGSSessionScreenIsLocked yet
        var liveReads = 0
        var loads = 0
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { loads += 1; return key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { [syntheticDisplay(1)] }, liveSession: { liveReads += 1; return observed },
                                   keepAwake: KeepAwakeRecorder().hold, uptime: { clock.now })
        model.start()
        model.receiveSessionNotice(.locked)
        gate.release()
        await drainMainActor()
        let readsAtLock = liveReads
        clock.advance(by: 0.25)
        model.selfHealRemoteHosting()
        runner.expectEqual(liveReads, readsAtLock, "the backstop does not look on the next watchdog tick after a pause")
        clock.advance(by: CompanionModel.selfHealInterval)
        model.selfHealRemoteHosting()
        runner.expect(liveReads > readsAtLock, "it looks once a full interval has passed")
        runner.expect(!model.restartPending, "inside the grace window the notice outranks a live session still reporting unlocked")
        // A restart scheduled by mistake would fire within a second; nothing may reach start().
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        runner.expectEqual(loads, 1, "nothing starts on the locked Mac")
        observed.screenLocked = true
        clock.advance(by: CompanionModel.selfHealInterval + 1)
        model.selfHealRemoteHosting()
        runner.expect(!model.restartPending, "once macOS reports the lock the host stays paused")
        // The unlock notice is lost; macOS now reports the Mac unlocked.
        observed.screenLocked = false
        clock.advance(by: CompanionModel.selfHealInterval + 1)
        model.selfHealRemoteHosting()
        runner.expect(model.restartPending, "past the grace window a lost unlock notice is still recovered")
        await waitUntil(seconds: 3) { loads >= 2 }
        runner.expect(loads >= 2, "and the host starts again on its own")
        model.stop()
    }

    await runner.check("Recovery backoff doubles to its ceiling and only a stable session starts it over") {
        var backoff = RemoteRecoveryBackoff()
        runner.expectEqual(backoff.delaySeconds, 1, "a resume with no failure behind it is prompt")
        var delays: [Int] = []
        for _ in 0..<7 { backoff.recordFailure(at: 0); delays.append(backoff.delaySeconds) }
        runner.expectEqual(delays, [2, 4, 8, 16, 30, 30, 30], "the existing schedule is unchanged")
        runner.expect(!RemoteRecoveryBackoff.isStable(sharingFor: 5), "a session that fails within seconds is flapping")
        runner.expect(RemoteRecoveryBackoff.isStable(sharingFor: RemoteRecoveryBackoff.stableSessionSeconds), "a minute of sharing has recovered")
        backoff.reset()
        runner.expectEqual(backoff.delaySeconds, 1, "reset makes the next resume prompt")
        runner.expectEqual(RemoteRecoveryBackoff.status("Capture stopped: gone.", retryingIn: 4), "Capture stopped: gone. Retrying in 4 s.", "keeps punctuation")
        runner.expectEqual(RemoteRecoveryBackoff.status("Capture stopped: gone", retryingIn: 2), "Capture stopped: gone. Retrying in 2 s.", "adds a full stop")
        runner.expectEqual(RemoteRecoveryBackoff.status(" ", retryingIn: 8), "Retrying in 8 s.", "an empty reason")
    }

    await runner.check("A stall past the heartbeat window does not latch granted control off") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, saveRemoteConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        model.testMode = true
        model.connected = true
        model.receive(DeskMessage(kind: "heartbeat"))
        model.enableInput()
        runner.expect(model.controlEnabled, "the owner granted control")
        // The main thread stalls past the window, then a queued burst is processed in wire order
        // with an input ahead of the next heartbeat, before the watchdog can tick. A deliberate
        // synchronous block is the point: it is exactly what lets the input arrive first.
        usleep(1_600_000)
        model.receive(DeskMessage(kind: "input", displayID: CGMainDisplayID(), x: 0.5, y: 0.5, action: "move"))
        runner.expect(!model.controlEnabled, "a stale input is still refused and input released")
        runner.expectEqual(model.inputCount, 0, "the stale input is not applied")
        model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(model.controlEnabled, "the next heartbeat restores the grant, as the watchdog path always did")
        model.revoke()
        model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(!model.controlEnabled, "an owner Stop still holds")
        model.stop()
    }
}
