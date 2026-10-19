import Foundation

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
