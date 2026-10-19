// Guided setup evaluation shared by the Mac companion UI and its tests.
//
// Every value here is derived from state the companion can actually observe:
// display inventory, permission preflights, capture state, and session state.
// It deliberately never claims that pixels reached the headset, never claims
// that an app under the pointer reacted to an event, and never carries a
// pairing key, whether a one-session key or a remembered one.
//
// Control names quoted in the guidance are the companion's current titles:
// Start Sharing & Control, Stop Sharing, Show Pairing Key, Allow Screen
// Recording, Allow Accessibility, Enable Test Input, Enable Mac Control, and
// the Sharing & Pairing section. Renaming one of those means updating it here.

public enum SetupStatus: String, Sendable {
    /// Observed working right now.
    case ready
    /// Already under way, with nothing to do on this Mac: capture is starting,
    /// or a host with remembered pairing is waiting for its headset to connect.
    case inProgress
    /// A concrete next action is required.
    case actionNeeded
    /// Intentionally off. Not a problem to fix.
    case inactive

    public var label: String {
        switch self {
        case .ready: return "Ready"
        // Covers both in-progress states: capture starting, and a remembered headset not yet connected.
        case .inProgress: return "Waiting"
        case .actionNeeded: return "Action needed"
        case .inactive: return "Off"
        }
    }
}

public enum SetupTrack: String, Sendable, CaseIterable, Identifiable {
    case viewing
    case testInput
    case macControl

    public var id: String { rawValue }

    public var shortTitle: String {
        switch self {
        case .viewing: return "Viewing"
        case .testInput: return "Test input"
        case .macControl: return "Mac control"
        }
    }

    public var title: String {
        switch self {
        case .viewing: return "Viewing your Mac"
        case .testInput: return "Test input (no pointer movement)"
        case .macControl: return "Real Mac control"
        }
    }
}

public enum SetupCheckID: String, Sendable {
    case displays
    case screenRecording
    case sharing
    case headset
    case testInput
    case accessibility
    case macControl
}

public struct SetupCheck: Sendable, Equatable, Identifiable {
    public let id: SetupCheckID
    public let track: SetupTrack
    public let title: String
    public let status: SetupStatus
    /// What the Mac observed, phrased without promises about the headset.
    public let detail: String
    /// The exact next action. Always present when `status` is `.actionNeeded`.
    public let nextStep: String?
}

/// Observed facts taken from the companion's published state.
public struct SetupSnapshot: Sendable, Equatable {
    public var displayCount: Int
    public var screenRecordingAllowed: Bool
    public var accessibilityAllowed: Bool
    public var preparing: Bool
    public var sharing: Bool
    public var connected: Bool
    public var controlEnabled: Bool
    public var testMode: Bool
    /// Whether a pairing key is on screen right now. The key value itself is never passed in.
    public var pairingKeyReady: Bool
    /// Whether this Mac hosts with remembered pairing: a saved headset connects with the key it
    /// stored, so a session that has ended or not started yet calls for no new key and no
    /// restart. False keeps the one-session guidance.
    public var rememberedPairing: Bool
    /// A retained pairing reached through the nearby Bonjour list rather than a fixed address.
    public var nearbyPairing: Bool

    public init(displayCount: Int = 0,
                screenRecordingAllowed: Bool = false,
                accessibilityAllowed: Bool = false,
                preparing: Bool = false,
                sharing: Bool = false,
                connected: Bool = false,
                controlEnabled: Bool = false,
                testMode: Bool = true,
                pairingKeyReady: Bool = false,
                rememberedPairing: Bool = false,
                nearbyPairing: Bool = false) {
        self.displayCount = displayCount
        self.screenRecordingAllowed = screenRecordingAllowed
        self.accessibilityAllowed = accessibilityAllowed
        self.preparing = preparing
        self.sharing = sharing
        self.connected = connected
        self.controlEnabled = controlEnabled
        self.testMode = testMode
        self.pairingKeyReady = pairingKeyReady
        self.rememberedPairing = rememberedPairing
        self.nearbyPairing = nearbyPairing
    }
}

public struct SetupReadiness: Sendable, Equatable {
    public static let recommendedDisplayCount = 4
    public static let maximumSharedDisplayCount = 4
    public static let startingMessage = "Capture is starting. Give it a moment."

    public let displays: SetupCheck
    public let screenRecording: SetupCheck
    public let sharing: SetupCheck
    public let headset: SetupCheck
    public let testInput: SetupCheck
    public let accessibility: SetupCheck
    public let macControl: SetupCheck
    /// Non-blocking reminder about the four-display goal.
    public let displayGoalNote: String?
    /// Sharing is running on a host with remembered pairing and no headset has connected. That
    /// is a wait, not a blocker, so it never reads as ready and never asks for a new key.
    private let waitingForRememberedHeadset: Bool

    public init(snapshot: SetupSnapshot) {
        // A session only counts as live when capture is running and a headset
        // is attached, so stopped capture can never read as ready.
        let live = snapshot.sharing && snapshot.connected && !snapshot.preparing
        waitingForRememberedHeadset = snapshot.rememberedPairing && snapshot.sharing
            && !snapshot.connected && !snapshot.preparing
        displays = Self.displayCheck(snapshot)
        screenRecording = Self.screenRecordingCheck(snapshot)
        sharing = Self.sharingCheck(snapshot)
        headset = Self.headsetCheck(snapshot, live: live)
        testInput = Self.testInputCheck(snapshot, live: live)
        accessibility = Self.accessibilityCheck(snapshot)
        macControl = Self.macControlCheck(snapshot, live: live)
        displayGoalNote = Self.goalNote(snapshot.displayCount)
    }

    /// Dependency order: everything needed to see the Mac, then input.
    public var checks: [SetupCheck] {
        [displays, screenRecording, sharing, headset, testInput, accessibility, macControl]
    }

    /// The first blocked step in dependency order. A step that is already under
    /// way wins over anything that depends on it finishing, and gives its own
    /// guidance when it has some (a remembered headset still to connect) or the
    /// starting message otherwise.
    public var primaryNextStep: String? {
        let ordered = checks
        let pending = ordered.firstIndex { $0.status == .actionNeeded }
        let starting = ordered.firstIndex { $0.status == .inProgress }
        switch (pending, starting) {
        case let (pendingIndex?, startingIndex?):
            return pendingIndex < startingIndex
                ? (ordered[pendingIndex].nextStep ?? ordered[pendingIndex].detail)
                : (ordered[startingIndex].nextStep ?? Self.startingMessage)
        case let (pendingIndex?, nil):
            return ordered[pendingIndex].nextStep ?? ordered[pendingIndex].detail
        case let (nil, startingIndex?):
            return ordered[startingIndex].nextStep ?? Self.startingMessage
        case (nil, nil):
            return nil
        }
    }

    public var headline: String {
        switch status(of: .viewing) {
        case .ready:
            if status(of: .macControl) == .ready { return "Sharing session connected. Mac control is enabled." }
            if status(of: .testInput) == .ready { return "Sharing session connected. Test input counts gestures only." }
            return "Sharing session connected. Input is not enabled."
        case .inProgress:
            return waitingForRememberedHeadset
                ? "Sharing is running. Waiting for the remembered Vision Pro to connect."
                : "Starting capture for your displays."
        default:
            return "Not ready to view this Mac in the headset yet."
        }
    }

    /// A track reports the status of its final step unless an earlier step
    /// needs attention, so a granted permission alone never reads as ready.
    public func status(of track: SetupTrack) -> SetupStatus {
        let tracked = checks.filter { $0.track == track }
        if tracked.contains(where: { $0.status == .actionNeeded }) { return .actionNeeded }
        if tracked.contains(where: { $0.status == .inProgress }) { return .inProgress }
        return tracked.last?.status ?? .inactive
    }

    private static func plural(_ count: Int, _ singular: String, _ many: String) -> String {
        count == 1 ? singular : many
    }

    private static func goalNote(_ count: Int) -> String? {
        guard count >= 1, count < recommendedDisplayCount else { return nil }
        let missing = recommendedDisplayCount - count
        return "Working with \(count) of \(recommendedDisplayCount) displays, which is a usable setup today. "
            + "Connect the other \(missing) \(plural(missing, "monitor", "monitors")) to reach the four-screen goal. "
            + "VisionDesk streams displays macOS already has; it does not create new ones."
    }

    private static func displayCheck(_ snapshot: SetupSnapshot) -> SetupCheck {
        let title = "Displays connected"
        let count = snapshot.displayCount
        if count <= 0 {
            return SetupCheck(id: .displays, track: .viewing, title: title, status: .actionNeeded,
                              detail: "macOS reports no usable display.",
                              nextStep: "Connect or wake a display. This panel rechecks on its own while sharing is stopped.")
        }
        if count > maximumSharedDisplayCount {
            let extra = count - maximumSharedDisplayCount
            return SetupCheck(id: .displays, track: .viewing, title: title, status: .actionNeeded,
                              detail: "\(count) displays connected. Sharing supports up to \(maximumSharedDisplayCount).",
                              nextStep: "Disconnect \(extra) \(plural(extra, "display", "displays")) before starting to share.")
        }
        let detail = count == recommendedDisplayCount
            ? "All \(recommendedDisplayCount) displays connected."
            : "\(count) of \(recommendedDisplayCount) displays connected. One display is enough to work."
        return SetupCheck(id: .displays, track: .viewing, title: title, status: .ready,
                          detail: detail, nextStep: nil)
    }

    private static func screenRecordingCheck(_ snapshot: SetupSnapshot) -> SetupCheck {
        let title = "Screen recording permission"
        guard snapshot.screenRecordingAllowed else {
            return SetupCheck(id: .screenRecording, track: .viewing, title: title, status: .actionNeeded,
                              detail: "Not allowed when macOS was last asked.",
                              nextStep: "Choose Allow Screen Recording, approve VisionDeskMac in Privacy & Security → Screen & System Audio Recording, then relaunch if macOS asks.")
        }
        return SetupCheck(id: .screenRecording, track: .viewing, title: title, status: .ready,
                          detail: "Allowed when macOS was last asked.", nextStep: nil)
    }

    private static func sharingCheck(_ snapshot: SetupSnapshot) -> SetupCheck {
        let title = "Screen sharing running"
        if snapshot.preparing {
            return SetupCheck(id: .sharing, track: .viewing, title: title, status: .inProgress,
                              detail: "Preparing capture for the connected displays.", nextStep: nil)
        }
        guard snapshot.sharing else {
            return SetupCheck(id: .sharing, track: .viewing, title: title, status: .actionNeeded,
                              detail: "Capture is stopped. Nothing is leaving this Mac.",
                              nextStep: "Choose Start Sharing & Control.")
        }
        let count = snapshot.displayCount
        return SetupCheck(id: .sharing, track: .viewing, title: title, status: .ready,
                          detail: "Capture is running for \(count) \(plural(count, "display", "displays")).",
                          nextStep: nil)
    }

    private static func headsetCheck(_ snapshot: SetupSnapshot, live: Bool) -> SetupCheck {
        let title = "Vision Pro session"
        if live {
            return SetupCheck(id: .headset, track: .viewing, title: title, status: .ready,
                              detail: "A paired Vision Pro session is connected.", nextStep: nil)
        }
        if snapshot.preparing {
            return SetupCheck(id: .headset, track: .viewing, title: title, status: .inProgress,
                              detail: "Waiting for capture to finish starting.", nextStep: nil)
        }
        guard snapshot.sharing else {
            return SetupCheck(id: .headset, track: .viewing, title: title, status: .actionNeeded,
                              detail: "No live session, because sharing is stopped on this Mac.",
                              nextStep: snapshot.rememberedPairing
                                  ? "Choose Start Sharing & Control, then open VisionDesk on Vision Pro and choose this Mac's saved card."
                                  : "Start sharing on this Mac, then pair from Vision Pro.")
        }
        if snapshot.rememberedPairing { return rememberedHeadsetCheck(snapshot, title: title) }
        guard snapshot.pairingKeyReady else {
            return SetupCheck(id: .headset, track: .viewing, title: title, status: .actionNeeded,
                              detail: "Sharing is running, but there is no session key and no headset connected.",
                              nextStep: "Choose Stop Sharing, then Start Sharing & Control for a fresh one-session key.")
        }
        return SetupCheck(id: .headset, track: .viewing, title: title, status: .actionNeeded,
                          detail: "Sharing is running and waiting for the headset to pair.",
                          nextStep: "On Vision Pro, open VisionDesk and enter the one-session key shown under Sharing & Pairing.")
    }

    /// How a saved headset reaches a host with remembered pairing.
    private static let rememberedConnectStep = "On Vision Pro, open VisionDesk and choose this Mac's saved card."

    /// A host with remembered pairing that is sharing with no headset attached is waiting, not
    /// blocked: the saved headset connects with the key it already holds. Stopping for a fresh
    /// key would only interrupt it, and a restart brings back the same remembered key anyway.
    private static func rememberedHeadsetCheck(_ snapshot: SetupSnapshot, title: String) -> SetupCheck {
        guard snapshot.pairingKeyReady else {
            return SetupCheck(id: .headset, track: .viewing, title: title, status: .inProgress,
                              detail: "Sharing is running and waiting for the remembered Vision Pro to connect.",
                              nextStep: "\(rememberedConnectStep) To pair a different headset, choose Show Pairing Key.")
        }
        let firstPairing = snapshot.nearbyPairing
            ? "choose this Mac in the nearby list and enter the pairing key shown on this Mac."
            : "choose Connect by Address, then enter this Mac's address and the pairing key shown on this Mac."
        return SetupCheck(id: .headset, track: .viewing, title: title, status: .inProgress,
                          detail: "Sharing is running and waiting for a Vision Pro to connect. This Mac's pairing key is on screen.",
                          nextStep: "\(rememberedConnectStep) To pair a headset that has not saved this Mac, \(firstPairing)")
    }

    private static func testInputCheck(_ snapshot: SetupSnapshot, live: Bool) -> SetupCheck {
        let title = "Test input enabled"
        guard snapshot.testMode else {
            return SetupCheck(id: .testInput, track: .testInput, title: title, status: .inactive,
                              detail: "Test mode is off, so gestures are set to control the Mac for real.",
                              nextStep: nil)
        }
        if live, snapshot.controlEnabled {
            return SetupCheck(id: .testInput, track: .testInput, title: title, status: .ready,
                              detail: "Enabled. Gestures are counted and echoed in the UI; the Mac pointer does not move.",
                              nextStep: nil)
        }
        guard live else {
            return SetupCheck(id: .testInput, track: .testInput, title: title, status: .actionNeeded,
                              detail: snapshot.controlEnabled
                                  ? "Marked enabled without a live headset session."
                                  : "Not enabled. A live sharing session with the headset is required first.",
                              nextStep: "Finish the viewing steps above, then choose Enable Test Input.")
        }
        return SetupCheck(id: .testInput, track: .testInput, title: title, status: .actionNeeded,
                          detail: "Not enabled yet. No gestures are being accepted.",
                          nextStep: "Choose Enable Test Input.")
    }

    private static func accessibilityCheck(_ snapshot: SetupSnapshot) -> SetupCheck {
        let title = "Accessibility permission"
        if snapshot.accessibilityAllowed {
            return SetupCheck(id: .accessibility, track: .macControl, title: title, status: .ready,
                              detail: "Allowed. Real Mac control can be enabled.", nextStep: nil)
        }
        guard snapshot.testMode else {
            return SetupCheck(id: .accessibility, track: .macControl, title: title, status: .actionNeeded,
                              detail: "Not allowed, and Test mode is off.",
                              nextStep: "Choose Allow Accessibility, approve VisionDeskMac in Privacy & Security → Accessibility, then enable Mac control again.")
        }
        return SetupCheck(id: .accessibility, track: .macControl, title: title, status: .inactive,
                          detail: "Not allowed. Test mode does not need it.",
                          nextStep: "Allow Accessibility before you turn Test mode off.")
    }

    private static func macControlCheck(_ snapshot: SetupSnapshot, live: Bool) -> SetupCheck {
        let title = "Mac control enabled"
        guard !snapshot.testMode else {
            return SetupCheck(id: .macControl, track: .macControl, title: title, status: .inactive,
                              detail: "Test mode is on, so no pointer or keyboard events reach macOS.",
                              nextStep: "Turn Test mode off for real control. Switching modes also stops input until you enable it again.")
        }
        guard snapshot.accessibilityAllowed else {
            return SetupCheck(id: .macControl, track: .macControl, title: title, status: .actionNeeded,
                              detail: snapshot.controlEnabled
                                  ? "Marked enabled while Accessibility permission is missing; the next event releases input."
                                  : "Not enabled. Accessibility permission is missing.",
                              nextStep: "Allow Accessibility, then choose Enable Mac Control.")
        }
        guard live else {
            return SetupCheck(id: .macControl, track: .macControl, title: title, status: .actionNeeded,
                              detail: snapshot.controlEnabled
                                  ? "Marked enabled without a live headset session."
                                  : "Not enabled. A live sharing session with the headset is required first.",
                              nextStep: "Finish the viewing steps above, then choose Enable Mac Control.")
        }
        guard snapshot.controlEnabled else {
            return SetupCheck(id: .macControl, track: .macControl, title: title, status: .actionNeeded,
                              detail: "Not enabled yet. No events are reaching macOS.",
                              nextStep: "Choose Enable Mac Control.")
        }
        return SetupCheck(id: .macControl, track: .macControl, title: title, status: .ready,
                          detail: "Enabled for the shared displays. The event counter shows what the headset sent; it does not prove the app under the pointer reacted.",
                          nextStep: nil)
    }
}
