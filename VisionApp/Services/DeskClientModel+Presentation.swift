import Foundation

/// Describes decoded-frame age, never network latency. Keeping the clock input explicit also
/// prevents a non-finite timestamp from reaching an integer conversion in the UI.
enum ConnectionDiagnostics {
    static func frameAge(receivedAt: TimeInterval?, now: TimeInterval) -> String {
        guard let receivedAt, receivedAt.isFinite, now.isFinite else { return "No decoded frame yet" }
        let seconds = max(0, now - receivedAt)
        if seconds < 1 { return "Less than 1 second ago" }
        if seconds >= 3_600 { return "Over an hour ago" }
        return "\(Int(seconds)) seconds ago"
    }

    static func recoveryAdvice(isLinked: Bool, isResponsive: Bool, hasDisplays: Bool,
                               retryExhausted: Bool, isRetrying: Bool) -> String {
        if isLinked {
            if !isResponsive { return "Check that your Mac is awake and on the network. Reconnect to try the connection again." }
            if !hasDisplays { return "Check Screen Recording permission and the selected displays in VisionDesk on your Mac." }
            return "When control is enabled, a paused screen accepts input again after a fresh frame arrives. For viewing only, choose Request Control or enable control on your Mac."
        }
        if retryExhausted { return "Automatic attempts have finished. Check that your Mac is awake and sharing, then choose Connect again." }
        if isRetrying { return "Keep VisionDesk open while it tries your saved connection again." }
        return "Start Sharing in VisionDesk on your Mac, then choose it here. Use the same network for nearby discovery."
    }
}

/// What the views say about the session, derived in one place from the state the gates use, so
/// the badge, the overview's control card and the key field never disagree with the buttons.
extension DeskClientModel {
    /// From the wearer's Stop until the Mac answers it. Nothing from this headset reaches the Mac
    /// meanwhile, and no grant is believed.
    var isStopPending: Bool { isLinked && stopAwaitingAcknowledgement }

    var connectionLabel: String {
        // A silent Mac outranks the grant: control that cannot reach the Mac is not control.
        if isLinked, !isMacResponsive { return "Not responding" }
        if canControl { return "Control enabled" }
        if isLinked { return "Viewing only" }
        if isReconnecting { return "Reconnecting" }
        if isConnecting { return "Connecting" }
        return "Not connected"
    }

    /// The overview's control card: what is true now and the one control action that applies.
    var controlSummary: SessionCopy.ControlSummary {
        SessionCopy.controlSummary(isControlEnabled: isMacControlEnabled, isStopPending: isStopPending,
                                   isMacResponsive: isMacResponsive, macStatus: statusText)
    }

    /// How far the typed pairing key has got, for the line under its field. Counts only.
    var keyEntry: SessionCopy.KeyEntry { SessionCopy.keyEntry(pairingCode) }
}
