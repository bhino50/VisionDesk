import AppKit
import CoreGraphics
import Foundation

/// Non-secret preferences. The pairing credential is stored separately in Keychain.
struct RemoteHostConfiguration: Equatable {
    var enabled: Bool
    var address: String
    var allowControl: Bool
    var keepAwake: Bool

    static let disabled = Self(enabled: false, address: "", allowControl: false, keepAwake: true)

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(enabled: defaults.bool(forKey: "remote.enabled"),
             address: defaults.string(forKey: "remote.address") ?? "",
             allowControl: defaults.bool(forKey: "remote.allowControl"),
             keepAwake: defaults.object(forKey: "remote.keepAwake") as? Bool ?? true)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "remote.enabled")
        defaults.set(address, forKey: "remote.address")
        defaults.set(allowControl, forKey: "remote.allowControl")
        defaults.set(keepAwake, forKey: "remote.keepAwake")
    }
}

// MARK: - Unattended availability
//
// The types below decide how an unattended remote workstation stays reachable. They sit beside
// the preferences they serve, and each is pure or injectable, so the behavior harness can
// exercise every decision without sleeping, locking or capturing anything on this Mac.

/// The idle-sleep hold a remote workstation keeps while it is shared, and while it is
/// recovering so that it can be shared again.
///
/// Releasing the hold is not neutral on an unattended Mac. Its user idle time keeps growing
/// while the hold prevents sleep, so when the hold is released the idle timers are usually
/// already past their settings and macOS can put the display to sleep at once. A sleeping
/// display pauses sharing (`screensDidSleepNotification`), and nothing remote can wake it. So a
/// stop that only rebuilds capture keeps the hold, and a stop that ends sharing — the owner's,
/// a lock, a sleep, a terminal failure — gives it up.
final class KeepAwakeHold {
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var activity: NSObjectProtocol?

    var isHeld: Bool { activity != nil }

    /// Defaults to the real process activity. Checks inject a recorder instead, so running them
    /// never creates a power assertion on the Mac.
    init(begin: @escaping () -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                                                  reason: "Keep your remote VisionDesk workstation available")
         },
         end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin
        self.end = end
    }

    /// Idempotent: an existing hold is kept, never stacked.
    func hold() {
        guard activity == nil else { return }
        activity = begin()
    }

    /// Idempotent, and safe to call from `deinit`.
    func release() {
        guard let current = activity else { return }
        activity = nil
        end(current)
    }
}

/// How long an unattended remote host waits before starting sharing again, and how long it may
/// keep the Mac awake while those starts keep failing.
///
/// The schedule itself is unchanged: 1 second for a resume with no failure behind it (wake,
/// unlock, a display change), then 2, 4, 8, 16 and at most 30 seconds after failures. What
/// changed is when it starts over. Every successful start used to reset it, so a capture that
/// came up and failed again seconds later restarted every two seconds indefinitely — and each
/// restart stops the listener, which disconnects the headset. Now only a session that stays up
/// for `stableSessionSeconds` counts as recovered, and one that keeps failing sooner backs off.
///
/// Keeping the Mac awake through a restart is what lets an unattended host come back. Keeping it
/// awake through a failure that never clears held the Mac and every display awake indefinitely
/// while nothing was shared. So the hold lasts `keepAwakeLimitSeconds` from the first failure of
/// a run. Ten minutes covers the whole ramp plus about twenty attempts at the 30-second ceiling,
/// longer than the transient causes take to clear: the capture service restarting, a display
/// rearranging, the login keychain unlocking, the network re-routing. Past it the hold is
/// released and the Mac follows its own energy settings, which VisionDesk never changes, while
/// restarts continue at the ceiling until one succeeds, the session pauses the host, or the owner
/// stops it.
struct RemoteRecoveryBackoff: Equatable {
    static let maximumAttempt = 5
    static let maximumDelaySeconds = 30
    static let stableSessionSeconds: TimeInterval = 60
    static let keepAwakeLimitSeconds: TimeInterval = 10 * 60

    private(set) var attempt = 0
    /// Uptime of the first failure since the host last shared stably or was paused on purpose.
    private(set) var failingSince: TimeInterval?

    var delaySeconds: Int { min(Self.maximumDelaySeconds, 1 << min(attempt, Self.maximumAttempt)) }

    mutating func recordFailure(at uptime: TimeInterval) {
        attempt = min(attempt + 1, Self.maximumAttempt)
        if failingSince == nil { failingSince = uptime }
    }

    /// Called once a session has stayed up long enough, and when sharing is suspended on
    /// purpose, so the resume that follows is prompt and a later failure gets a full window.
    mutating func reset() {
        attempt = 0
        failingSince = nil
    }

    /// Whether a restart scheduled at `uptime` may keep the Mac awake while it waits.
    func keepsAwake(at uptime: TimeInterval) -> Bool {
        guard let failingSince else { return true }
        return uptime - failingSince < Self.keepAwakeLimitSeconds
    }

    static func isStable(sharingFor duration: TimeInterval) -> Bool { duration >= stableSessionSeconds }

    /// A failure explanation followed by when the next automatic attempt happens, so the owner
    /// can tell a host that is recovering from one that has given up — and, past the window,
    /// that it no longer keeps the Mac awake meanwhile.
    static func status(_ reason: String, retryingIn seconds: Int, keepingAwake: Bool = true) -> String {
        let retry = "Retrying in \(seconds) s."
        let note = keepingAwake ? retry : "\(retry) This Mac is no longer kept awake while it retries."
        let sentence = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = sentence.last else { return note }
        return ".!?)".contains(last) ? "\(sentence) \(note)" : "\(sentence). \(note)"
    }
}

/// What macOS reports about the console session right now. Read directly, never cached.
struct HostSessionObservation: Equatable {
    var onConsole: Bool
    var screenLocked: Bool
    var displaysAsleep: Bool

    /// The session is this Mac's to share: on the console and unlocked.
    var isAvailable: Bool { onConsole && !screenLocked }

    static func current() -> HostSessionObservation {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return HostSessionObservation(
            onConsole: session?[kCGSessionOnConsoleKey as String] as? Bool == true,
            screenLocked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false,
            displaysAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0
        )
    }
}

/// A session notification, reduced to what it means for remote sharing.
enum HostSessionNotice: CaseIterable {
    case locked, unlocked, willSleep, didWake, screensSlept, screensWoke, sessionResigned, sessionActivated

    /// A lock, a system or display sleep and a session switch pause sharing; their answers resume it.
    var pausesSharing: Bool {
        switch self {
        case .locked, .willSleep, .screensSlept, .sessionResigned: return true
        case .unlocked, .didWake, .screensWoke, .sessionActivated: return false
        }
    }
}

/// Session conditions learned from notifications, each of which pauses remote sharing.
///
/// Notifications remain the fast path, but a missed one used to strand an unattended host:
/// nothing checked again, so sharing stayed paused until someone came to the Mac. When the host
/// is idle but should be sharing, these flags are reconciled against a live observation.
///
/// A notice outranks that observation for `noticeGraceSeconds` of awake time. macOS can post a
/// lock, sleep or session notice before the session dictionary or display state reports it, and
/// reconciling at once would read the old state, clear the pause and restart sharing — with
/// granted control, onto the lock screen. Inside the window a live reading may add a pause but
/// never clear one; after it, a notice nothing has answered is presumed lost. `systemUptime` does
/// not advance while the Mac sleeps, so the window is always awake time. A sleep notice has no
/// live counterpart and is simply dropped once the window has passed.
struct HostSessionFlags: Equatable {
    static let noticeGraceSeconds: TimeInterval = 30

    var locked = false
    var sessionInactive = false
    var screensAsleep = false
    /// Awake uptime at the last `willSleepNotification` that no wake notice has answered.
    var sleepNoticeUptime: TimeInterval?
    /// Awake uptime of the most recent notice that paused sharing.
    var pauseNoticeUptime: TimeInterval?

    var sleeping: Bool { sleepNoticeUptime != nil }
    var blocksResume: Bool { locked || sleeping || sessionInactive || screensAsleep }

    mutating func apply(_ notice: HostSessionNotice, at uptime: TimeInterval) {
        switch notice {
        case .locked: locked = true
        case .unlocked: locked = false
        case .willSleep: sleepNoticeUptime = uptime
        case .didWake: sleepNoticeUptime = nil
        case .screensSlept: screensAsleep = true
        case .screensWoke: screensAsleep = false
        case .sessionResigned: sessionInactive = true
        case .sessionActivated: sessionInactive = false
        }
        if notice.pausesSharing { pauseNoticeUptime = uptime }
    }

    func reconciled(with live: HostSessionObservation, at uptime: TimeInterval) -> HostSessionFlags {
        var result = self
        let noticesSettled = pauseNoticeUptime.map { uptime - $0 >= Self.noticeGraceSeconds } ?? true
        result.locked = live.screenLocked || (locked && !noticesSettled)
        result.sessionInactive = !live.onConsole || (sessionInactive && !noticesSettled)
        result.screensAsleep = live.displaysAsleep || (screensAsleep && !noticesSettled)
        if let notice = sleepNoticeUptime, uptime - notice >= Self.noticeGraceSeconds {
            result.sleepNoticeUptime = nil
        }
        return result
    }
}

/// The macOS notifications a host acts on, delivered on the main actor until this is released:
/// sleep, wake and user switches from the workspace, locking from the distributed center, and
/// display rearrangements from the app's own center.
final class HostNotificationObserver {
    private var observations: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(session: @escaping @MainActor (HostSessionNotice) -> Void, displaysChanged: @escaping @MainActor () -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceNotices: [(Notification.Name, HostSessionNotice)] = [
            (NSWorkspace.willSleepNotification, .willSleep), (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.screensDidSleepNotification, .screensSlept), (NSWorkspace.screensDidWakeNotification, .screensWoke),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated)
        ]
        for (name, notice) in workspaceNotices { observe(workspace, name) { session(notice) } }
        for (name, notice) in [("com.apple.screenIsLocked", HostSessionNotice.locked), ("com.apple.screenIsUnlocked", .unlocked)] {
            observe(DistributedNotificationCenter.default(), NSNotification.Name(name)) { session(notice) }
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, displaysChanged)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observations.append((center, token))
    }

    deinit {
        for observation in observations { observation.center.removeObserver(observation.token) }
    }
}

// MARK: - Companion window
//
// A remote workstation keeps hosting with its window closed, so the menu bar item, a Dock click
// and a second launch are how the owner gets the window back. This sits with the host types,
// outside the SwiftUI scene, so the behavior harness can exercise it.

/// Shows the one companion window and keeps the window's comings and goings away from sharing.
///
/// The scene is a single `Window` with a stable identity, so opening it raises the window that is
/// already there, or recreates it if it was closed, and never adds a second. Launch-only work —
/// starting the configured remote host — runs the first time the window appears: closing and
/// reopening it later neither restarts sharing the owner stopped nor touches input or hosting.
///
/// Every method runs on the main actor. The type itself is not isolated, so the app delegate can
/// create it as a stored property.
final class CompanionWindowLifecycle {
    static let sceneID = "companion"

    private let activate: @MainActor () -> Void
    /// SwiftUI's action for opening the scene. Only views receive it, so the window and the menu
    /// bar item pass it on, and a Dock click or relaunch, which has no view, uses the latest one.
    private var openScene: (@MainActor () -> Void)?
    private var launched = false

    init(activate: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.activate = activate
    }

    @MainActor
    func register(openScene: @escaping @MainActor () -> Void) { self.openScene = openScene }

    /// Brings the companion window to the front with the app active. False until a view has
    /// supplied the action.
    @MainActor @discardableResult
    func show() -> Bool {
        guard let openScene else { return false }
        activate()
        openScene()
        return true
    }

    /// Answers `applicationShouldHandleReopen`. Once the window has been shown here, AppKit is told
    /// the reopen is handled and adds nothing; before any view has appeared, its default runs.
    @MainActor
    func shouldHandleReopen() -> Bool { !show() }

    /// Called whenever the window appears. Starts the configured host the first time only, and
    /// returns whether this was that first time.
    @MainActor
    func windowAppeared(_ model: CompanionModel, arguments: [String] = CommandLine.arguments) -> Bool {
        guard !launched else { return false }
        launched = true
        if let index = arguments.firstIndex(of: "--enable-remote-host"), index + 1 < arguments.count {
            model.configureRemoteAccess(address: arguments[index + 1], allowControl: true, keepAwake: true)
        }
        // Starts the saved host. Does nothing when the line above already restarted it; covers an
        // address that was already the saved one, which configuring leaves running as it is.
        model.startSavedHosting()
        return true
    }

    /// A remote host keeps sharing with its window closed. A local session has nothing to return
    /// to, so it ends with its window, as the app does.
    @MainActor
    func windowClosed(_ model: CompanionModel) {
        // The remembered listener remains available from the menu bar when this window closes.
    }
}
