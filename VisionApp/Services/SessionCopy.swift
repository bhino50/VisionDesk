import Foundation

/// The sentences the client shows about its connection and about whether a screen accepts
/// input. They live apart from the views and the model so each one can be checked directly and
/// reads the same wherever it appears: the overview, every display window and its footer.
enum SessionCopy {
    /// How a connection that never authenticated was started, which decides the advice. A saved
    /// Mac is not here: its first attempt is retried, and `gaveUp` advises on it instead.
    enum Route: Equatable {
        case nearby
        case address
    }

    /// What a display window shows when it has no screen to show.
    struct Placeholder: Equatable {
        let symbol: String
        let title: String
        let detail: String
        let showsProgress: Bool
    }

    static let notRespondingTitle = "Your Mac isn't responding"

    /// Pointer mode clicks where the Mac's pointer already is. Until something has placed it on
    /// a display there is no such place, and guessing one would move the pointer to click.
    static let pointerPlacementHint =
        "Pinch and move on the screen to place the pointer first. Taps then click where it is."

    /// The named accessibility action that places a display's pointer without clicking.
    static let placePointerActionName = "Place pointer at center"

    /// Spoken when an assistive click is refused for want of a placed pointer, so a refusal is
    /// never silent and always names the way forward.
    static let assistivePlacementHint =
        "Nothing was clicked. Place the pointer first with the \(placePointerActionName) action, or pinch and move on the screen."

    /// Shown while control is stopped from this headset and the Mac has not granted it again.
    static let controlStoppedStatus = "Control stopped. Enable control on your Mac to resume."

    /// What the overview says about control, and the one control action it offers.
    struct ControlSummary: Equatable {
        enum Action: Equatable {
            case requestControl
            case stopControl
            case none
        }

        enum Tone: Equatable {
            case active
            case neutral
            case attention
        }

        let title: String
        let detail: String
        let symbol: String
        let tone: Tone
        let action: Action
    }

    /// Derived from the same state the gates use, so the card never offers an action the model
    /// would refuse and never describes control differently from the badge beside it.
    ///
    /// Stop is offered exactly while the Mac's grant stands, silent or not: that is when there is
    /// something to stop. A request is offered only while there is no grant and no Stop of this
    /// headset's is unanswered. A pending Stop outranks everything, because from the moment it is
    /// pressed nothing from this headset reaches the Mac.
    static func controlSummary(isControlEnabled: Bool, isStopPending: Bool, isMacResponsive: Bool,
                               macStatus: String) -> ControlSummary {
        if isStopPending {
            return ControlSummary(title: "Control stopped",
                                  detail: "Nothing you do here reaches your Mac. Waiting for your Mac to confirm.",
                                  symbol: "stop.circle", tone: .neutral, action: .none)
        }
        if !isMacResponsive {
            return isControlEnabled
                ? ControlSummary(title: "Control paused", detail: "Input resumes when your Mac responds again.",
                                 symbol: "pause.circle", tone: .attention, action: .stopControl)
                : ControlSummary(title: "Viewing only", detail: "Waiting for your Mac to respond.",
                                 symbol: "pause.circle", tone: .attention, action: .none)
        }
        if isControlEnabled {
            return ControlSummary(title: "You're in control",
                                  detail: "Open a display, then pinch on its screen to point, click and scroll.",
                                  symbol: "cursorarrow.rays", tone: .active, action: .stopControl)
        }
        let status = macStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        return ControlSummary(title: "Viewing only",
                              detail: status.isEmpty ? "To use your Mac from here, enable control in VisionDesk on your Mac." : status,
                              symbol: "eye", tone: .neutral, action: .requestControl)
    }

    /// Why the keyboard panel accepts nothing right now. A window that is not active explains it
    /// on its own; otherwise it is whatever keeps the screen itself from accepting input.
    static func keyboardPaused(isWindowActive: Bool, canControlMac: Bool, isMacResponsive: Bool) -> String {
        guard isWindowActive else { return "Keyboard paused while this window isn't active." }
        let reason = controlHint(canControlDisplay: false, canControlMac: canControlMac,
                                 isMacResponsive: isMacResponsive, mode: .pointer, pointerPlaced: true)
        return "Keyboard paused. \(reason)"
    }

    /// Between scheduled attempts. A Mac reached in this session has been lost; a saved Mac that
    /// has not answered yet has not been — it may still be waking or starting to share.
    static func retrying(_ name: String, inSeconds seconds: UInt64, attempt: Int, of total: Int,
                         everConnected: Bool) -> String {
        let next = "Trying again in \(seconds)s (attempt \(attempt) of \(total))."
        return everConnected
            ? "Lost the connection to \(macName(name)). \(next)"
            : "Couldn't reach \(macName(name)) yet. \(next)"
    }

    static func reconnecting(to name: String, attempt: Int, of total: Int) -> String {
        "Reconnecting to \(macName(name)) (attempt \(attempt) of \(total))."
    }

    /// The way out when what is saved can no longer reach the saved Mac. Forget waits under More on
    /// the saved card, so the advice says where it is.
    static let forgetSavedMacAdvice = "Choose More, then Forget This Mac, and pair with it again."

    /// The schedule gave up. A saved Mac that never answered may have had its pairing reset, which
    /// changes its key, so that case names the one fix that helps.
    static func gaveUp(on name: String, everConnected: Bool) -> String {
        let summary = "Could not reach \(macName(name)) after several tries."
        return everConnected
            ? "\(summary) Connect again once your Mac is awake and on the network."
            : "\(summary) Make sure your Mac is awake and sharing. If its pairing was reset, its key changed: choose More, then Forget This Mac, and pair with the new key."
    }

    static func notRespondingDetail(seconds: TimeInterval, willRecover: Bool, canReconnect: Bool) -> String {
        let whole = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let quiet = "Nothing has arrived from your Mac for \(whole) s."
        if willRecover {
            return "\(quiet) VisionDesk reconnects on its own if this continues. Choose Reconnect to try now."
        }
        if canReconnect { return "\(quiet) Choose Reconnect to try again." }
        return "\(quiet) If it went to sleep or left the network, disconnect and pair again."
    }

    static func displayPlaceholder(
        isLinked: Bool, isReconnecting: Bool, isConnecting: Bool, macName name: String
    ) -> Placeholder {
        if isLinked {
            return Placeholder(symbol: "display.trianglebadge.exclamationmark",
                               title: "This display is no longer available",
                               detail: "Open VisionDesk to choose one of your Mac’s connected displays.",
                               showsProgress: false)
        }
        if isReconnecting || isConnecting {
            // An automatic reconnection brings this same window back by itself, so telling
            // the wearer to go and connect would send them to do work that is already under way.
            return Placeholder(symbol: "arrow.triangle.2.circlepath",
                               title: "\(isReconnecting ? "Reconnecting" : "Connecting") to \(macName(name))…",
                               detail: "Keep this window open. Its screen returns here as soon as your Mac answers.",
                               showsProgress: true)
        }
        return Placeholder(symbol: "display",
                           title: "Your Mac is disconnected",
                           detail: "Connect in VisionDesk to bring your screens back.",
                           showsProgress: false)
    }

    /// Why a screen is paused. A silent link explains every paused screen at once, so it takes
    /// precedence over one stream's decode warning and over the generic sharing advice.
    static func pausedScreenDetail(decodeWarning: String?, isMacResponsive: Bool) -> String {
        if !isMacResponsive { return "Your Mac isn't responding. Check that it's awake and on the network." }
        return decodeWarning ?? "Check screen sharing in VisionDesk on your Mac."
    }

    /// One source for the "can I interact with this screen" copy, shared by the footer and the
    /// accessibility hint so they cannot disagree with the buttons beside them.
    static func controlHint(
        canControlDisplay: Bool, canControlMac: Bool, isMacResponsive: Bool,
        mode: ScreenInteractionMode, pointerPlaced: Bool
    ) -> String {
        if canControlDisplay {
            return mode == .pointer && !pointerPlaced ? pointerPlacementHint : mode.instruction
        }
        if canControlMac {
            return isMacResponsive
                ? "Waiting for a fresh frame from this screen before it accepts input."
                : "Your Mac isn't responding, so this screen can't accept input yet."
        }
        return "Viewing only. Enable control in VisionDesk on your Mac."
    }

    static func macName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your Mac" : trimmed
    }
}
