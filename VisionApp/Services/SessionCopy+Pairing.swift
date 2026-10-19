import Foundation

/// The words for the way in: finding a Mac, typing its pairing key, and why a connection did not
/// work. "Pairing key" throughout, because that is what VisionDesk on the Mac calls it.
extension SessionCopy {
    /// How far a typed pairing key has got, by the same rules as `PairingKey(string:)`: dashes,
    /// spaces and line breaks are ignored, case does not matter, and exactly 32 hexadecimal
    /// digits make a key. Only a count is ever derived, so nothing shown or spoken from this
    /// repeats any part of the key.
    enum KeyEntry: Equatable {
        case empty
        case partial(digits: Int)
        case tooLong(digits: Int)
        case invalidCharacters
        case complete
    }

    static let pairingKeyLength = 32

    static let incompleteKeyMessage = "Enter the complete pairing key shown in VisionDesk on your Mac."

    private static let hexadecimalDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    static func keyEntry(_ text: String) -> KeyEntry {
        var digits = 0
        for scalar in text.unicodeScalars where scalar != "-" && !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            guard hexadecimalDigits.contains(scalar) else { return .invalidCharacters }
            digits += 1
        }
        if digits == 0 { return .empty }
        if digits < pairingKeyLength { return .partial(digits: digits) }
        if digits > pairingKeyLength { return .tooLong(digits: digits) }
        return .complete
    }

    /// The line under the key field: what the key looks like, what is still missing, or that it
    /// is whole. Whether it is the right key only the Mac can say.
    static func keyEntryHint(_ entry: KeyEntry) -> String {
        switch entry {
        case .empty:
            return "The 32-character key shown in VisionDesk on your Mac. Dashes and spaces are optional."
        case let .partial(digits):
            return "\(digits) of \(pairingKeyLength) characters."
        case let .tooLong(digits):
            return "\(digits) characters. A pairing key has \(pairingKeyLength)."
        case .invalidCharacters:
            return "A pairing key uses only the numbers 0–9 and the letters A–F."
        case .complete:
            return "Pairing key complete."
        }
    }

    /// DeskTransport writes its reasons for both apps, so they speak of "the key" and "the other
    /// device". Each becomes what it means on this headset. A reason not listed here is shown
    /// as it is, so a new one is never lost.
    static func plainReason(_ reason: String) -> String {
        transportReasons[reason] ?? reason
    }

    private static let transportReasons: [String: String] = [
        // A wrong key ends here too: the handshake is never answered and runs out of time.
        "Pairing timed out. Check the key and local network.": "Pairing didn't finish in time.",
        "Secure pairing failed. Check the pairing key and local network.": "The secure connection couldn't be set up.",
        "The connection did not negotiate the required security.": "The secure connection couldn't be set up.",
        "The secure connection was interrupted.": "The connection was interrupted.",
        "Truncated frame.": "The connection was interrupted.",
        "The other device disconnected.": "Your Mac closed the connection.",
        "The other device stopped responding. Reconnect and try again.": "Your Mac stopped responding.",
        "The connection is too slow for control. Reconnect and try again.":
            "The connection became too slow to control your Mac safely.",
        "Invalid message length.": "Your Mac sent something this version of VisionDesk can't read.",
        "Invalid message.": "Your Mac sent something this version of VisionDesk can't read.",
        "The connection entered an unsupported state.": "The connection failed unexpectedly."
    ]

    /// A connection with a typed or discovered key that never completed its secure handshake.
    /// Nothing was established, so nothing was lost and nothing is retried. A wrong key and a
    /// Mac that never answered look the same from here, so the advice covers both, and says
    /// that what was typed is still there to check.
    static func couldNotConnect(to name: String, reason: String, route: Route) -> String {
        let advice: String
        switch route {
        case .nearby:
            advice = "Check that the pairing key you entered matches the one on your Mac and that your Mac is still sharing, then connect again."
        case .address:
            advice = "Check the address and pairing key you entered, and that your Mac is awake and reachable on your network or VPN, then connect again."
        }
        return "Couldn't connect to \(macName(name)). \(plainReason(reason)) \(advice)"
    }

    /// A nearby Mac's session ended unexpectedly. It is never dialled again — a Mac paired this
    /// way stops listening when its session ends — so the way back is pairing again.
    static func connectionEnded(with name: String, reason: String) -> String {
        "Lost the connection to \(macName(name)). \(plainReason(reason)) To connect again, start sharing on your Mac if it stopped, then enter the pairing key it shows."
    }

    /// The line under the saved Mac's name: where it is reached.
    static func savedMacDetail(_ mac: RememberedMac) -> String {
        mac.address ?? "On this network"
    }

    /// What the nearby list says while it has no Mac to show.
    struct DiscoveryGuidance: Equatable {
        let title: String
        let detail: String
        /// True when something has to change before any Mac can be found.
        let needsAttention: Bool
    }

    /// Turns the browser's status into what to do about it. Searching is normal and says how to
    /// make a Mac appear, and so is a search restarting by itself; missing Local Network access
    /// says where to grant it. A status not listed is shown as a problem in its own words.
    static func discoveryGuidance(status: String) -> DiscoveryGuidance {
        switch status {
        case "Looking for Macs ready to pair.", "Looking for nearby Macs…", "Discovery stopped.":
            return DiscoveryGuidance(
                title: "Looking for your Mac",
                detail: "Start sharing in VisionDesk on your Mac, and keep both devices on the same network.",
                needsAttention: false)
        case "Discovery was interrupted. Searching again shortly.":
            return DiscoveryGuidance(
                title: "Looking for your Mac",
                detail: "The search was interrupted and starts again by itself in a moment.",
                needsAttention: false)
        case "Waiting for access to the local network.":
            return DiscoveryGuidance(
                title: "Allow Local Network access",
                detail: "VisionDesk needs it to find your Mac. Allow it when asked, or turn it on for VisionDesk in Settings under Privacy & Security.",
                needsAttention: true)
        case "Could not discover Macs. Check Local Network access and try again.":
            return DiscoveryGuidance(
                title: "Couldn't search this network",
                detail: "Check that Local Network access is on for VisionDesk in Settings under Privacy & Security, then search again.",
                needsAttention: true)
        default:
            return DiscoveryGuidance(title: "Couldn't search this network", detail: status, needsAttention: true)
        }
    }
}
