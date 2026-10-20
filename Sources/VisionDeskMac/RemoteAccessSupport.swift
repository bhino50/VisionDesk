import Darwin
import DeskCore
import DeskTransport
import Foundation

// MARK: - This Mac's addresses

/// IP addresses on this Mac's network interfaces that are up right now.
///
/// `getifaddrs` reads the interface list from the kernel and sends nothing on the network, so a
/// host can ask before every start. Tailscale's address is listed only while Tailscale has this
/// Mac connected, and that is also the only time the listener can bind it.
enum LocalNetworkAddresses {
    static func ipv4() -> [String] { addresses(families: [AF_INET]) }
    /// Includes IPv6 for private VPN interfaces; enumeration is local and performs no DNS.
    static func all() -> [String] { addresses(families: [AF_INET, AF_INET6]) }

    private static func addresses(families: Set<Int32>) -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard Int32(entry.pointee.ifa_flags) & IFF_UP != 0, let socketAddress = entry.pointee.ifa_addr,
                  families.contains(Int32(socketAddress.pointee.sa_family)) else { continue }
            let family = Int32(socketAddress.pointee.sa_family)
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let written: String?
            if family == AF_INET {
                var address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                written = text.withUnsafeMutableBufferPointer { buffer in
                    inet_ntop(AF_INET, &address, buffer.baseAddress, socklen_t(buffer.count)).map { String(cString: $0) }
                }
            } else {
                var address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                written = text.withUnsafeMutableBufferPointer { buffer in
                    inet_ntop(AF_INET6, &address, buffer.baseAddress, socklen_t(buffer.count)).map { String(cString: $0) }
                }
            }
            if let written { addresses.append(written) }
        }
        return addresses
    }

    /// The addresses among `addresses` in the range Tailscale assigns, canonical and sorted.
    static func tailnet(_ addresses: [String]) -> [String] {
        Set(addresses.compactMap { RemoteMacAddress(host: $0) }.filter(\.isTailnetIPv4).map(\.host)).sorted()
    }
}

// MARK: - The remembered key

/// The remote pairing key in the login Keychain. Only the defaults of `CompanionModel`'s
/// initializer use this; checks pass closures over memory, so they never touch a real item.
enum RemoteHostKeychain {
    static let account = "mac.remote-v1"
    static func load() throws -> PairingKey? { try PairingKeyStore().load(account: account) }
    static func save(_ key: PairingKey) throws { try PairingKeyStore().save(key, account: account) }
    static func delete() throws { try PairingKeyStore().delete(account: account) }
}

/// How long a remembered pairing key stays on screen once shown. It always hides again, and at
/// once when a headset connects.
struct PairingKeyReveal: Equatable {
    /// Show Pairing Key.
    var onRequest: TimeInterval = 60
    /// The key made when remote access is turned on, which the owner needs for the first pairing.
    var firstPairing: TimeInterval = 5 * 60

    static let standard = PairingKeyReveal()
}

// MARK: - Answers in the remote access panel

/// The answer to something the owner just did in the remote access panel, shown right beside it.
struct RemoteFeedback: Equatable {
    enum Tone: Equatable { case confirmation, problem }
    /// A one-step way out of a problem, offered as a button next to the message.
    enum Fix: Equatable {
        case allowScreenRecording, allowAccessibility
        /// Fill in this Mac's own Tailscale address.
        case useAddress(String)
    }

    let message: String
    let tone: Tone
    var fix: Fix?

    static func done(_ message: String) -> RemoteFeedback { RemoteFeedback(message: message, tone: .confirmation) }
    static func problem(_ message: String, fix: Fix? = nil) -> RemoteFeedback { RemoteFeedback(message: message, tone: .problem, fix: fix) }

    static let needsScreenRecording = problem("Sharing this Mac needs Screen Recording access for VisionDeskMac.",
                                              fix: .allowScreenRecording)
    static let needsAccessibility = problem("Mac control needs Accessibility access for VisionDeskMac. Allow it, or turn control off to share view-only.",
                                            fix: .allowAccessibility)
}

/// What a request from the remote access panel did.
enum RemoteAccessChange: Equatable {
    /// Refused before anything was saved or started; `remoteFeedback` says why.
    case refused
    /// The address was already the saved one. Only preferences can have changed, and those apply
    /// without a restart, so a connected headset stays connected.
    case unchanged
    /// Saved, and sharing restarted at the address.
    case restarted
}

/// The checks a requested remote address must pass before anything is saved or started, and what
/// the owner is told when it does not.
enum RemoteAccessReview {
    /// A private IP literal on VisionDesk's fixed port. DNS is deliberately not resolved:
    /// the listener must bind an exact address owned by an active local interface.
    static func isPrivateHost(_ host: String) -> Bool {
        RemoteMacAddress(host: host)?.isPrivateIP == true
    }

    static func isOnThisMac(_ host: String, localAddresses: [String]) -> Bool {
        guard let requested = RemoteMacAddress(host: host), isPrivateHost(requested.host) else { return false }
        return localAddresses.contains { RemoteMacAddress(host: $0)?.host == requested.host }
    }

    static func privateAddresses(_ addresses: [String]) -> [String] {
        Set(addresses.compactMap { RemoteMacAddress(host: $0) }.filter { isPrivateHost($0.host) }.map(\.host)).sorted()
    }

    static func endpoint(from text: String) -> RemoteMacAddress? {
        guard let endpoint = RemoteMacAddress(string: text), isPrivateHost(endpoint.host),
              endpoint.port == RemoteMacAddress.defaultPort else { return nil }
        return endpoint
    }

    /// The address could not be read as an allowed private IP endpoint.
    static func unreadable(localAddresses: [String]) -> RemoteFeedback {
        if let own = onlyTailnetAddress(localAddresses) {
            return .problem("Enter this Mac's Tailscale address: \(own).", fix: .useAddress(own))
        }
        if let own = suggestedAddress(localAddresses) {
            return .problem("Enter this Mac's private VPN IP address: \(own).", fix: .useAddress(own))
        }
        return .problem("Enter this Mac's private VPN IP address. Use an IPv4 address or an IPv6 address in brackets. Connect both devices to the same VPN first.")
    }

    /// The address is well formed but this Mac does not have it.
    static func notOnThisMac(_ host: String, localAddresses: [String]) -> RemoteFeedback {
        let tailnet = LocalNetworkAddresses.tailnet(localAddresses)
        let own = RemoteMacAddress(host: host)?.isTailnetIPv4 == true && !tailnet.isEmpty
            ? tailnet : privateAddresses(localAddresses)
        let networkName = RemoteMacAddress(host: host)?.isTailnetIPv4 == true ? "Tailscale" : "private VPN"
        switch own.count {
        case 0:
            return .problem("\(host) isn't on this Mac right now. Make sure \(networkName) is connected on this Mac, then try again.")
        case 1:
            return .problem("\(host) isn't this Mac's \(networkName) address. This Mac's is \(own[0]).", fix: .useAddress(inputAddress(own[0])))
        default:
            return .problem("\(host) isn't one of this Mac's \(networkName) addresses: \(own.joined(separator: ", ")).")
        }
    }

    /// Why an unattended start is waiting. `RemoteRecoveryBackoff.status` adds when it retries.
    static func waitingForTailscale(_ host: String) -> String {
        let network = RemoteMacAddress(host: host)?.isTailnetIPv4 == true ? "Tailscale" : "the private VPN"
        return "Waiting for \(network) to connect this Mac at \(host)"
    }

    static func inputAddress(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }

    static func suggestedAddress(_ addresses: [String]) -> String? {
        if let tailnet = onlyTailnetAddress(addresses) { return tailnet }
        let own = privateAddresses(addresses)
        return own.count == 1 ? inputAddress(own[0]) : nil
    }

    static func onlyTailnetAddress(_ localAddresses: [String]) -> String? {
        let own = LocalNetworkAddresses.tailnet(localAddresses)
        return own.count == 1 ? own[0] : nil
    }
}

// MARK: - What the headset is told

/// What this Mac tells a connected headset when sharing ends or pauses, or when control is refused.
/// The headset shows these as they are, so each one says what happened and what happens next.
enum HeadsetNotice {
    static let stopped = "Sharing stopped on the Mac."
    static let quit = "VisionDesk quit on the Mac."
    static let restarting = "Sharing is restarting on the Mac. It reconnects in a moment."
    static let remoteTurnedOn = "The Mac switched to remote access. Pair again with its pairing key."
    static let addressChanged = "The Mac's address changed. On Vision Pro, add the Mac again with its new address."
    static let remoteTurnedOff = "Remote access was turned off on the Mac."
    static let stoppedFromMacControls = "Sharing was stopped from the Mac's screen-sharing controls."
    static let recordingNotAllowed = "Screen recording is no longer allowed for VisionDesk on the Mac."

    static let controlTurnedOff = "Control was turned off on the Mac. Viewing continues."
    static let controlNeedsAccessibility = "Mac control is unavailable: Accessibility access is off for VisionDesk on this Mac."

    static func displaysChanged(resumes: Bool) -> String {
        resumes ? "The Mac's displays changed. Sharing restarts in a moment."
                : "The Mac's displays changed. Start sharing again on the Mac."
    }

    static func tooManyDisplays(resumes: Bool) -> String {
        resumes ? "The Mac has more than four displays connected. Sharing resumes once one is disconnected."
                : "The Mac has more than four displays connected, so sharing stopped."
    }

    /// A lock, a sleep or a user switch on the Mac. Only a remote host resumes on its own.
    static func paused(by notice: HostSessionNotice, resumes: Bool) -> String {
        let event: String
        let ends: String
        switch notice {
        case .locked: (event, ends) = ("The Mac locked", "it is unlocked")
        case .willSleep: (event, ends) = ("The Mac is going to sleep", "it wakes")
        case .screensSlept: (event, ends) = ("The Mac's displays went to sleep", "they wake")
        case .sessionResigned: (event, ends) = ("The Mac switched to another user", "the user switches back")
        case .unlocked, .didWake, .screensWoke, .sessionActivated: return stopped
        }
        return resumes ? "\(event). Sharing resumes when \(ends)." : "\(event), so sharing stopped."
    }

    /// The answer to a headset asking for control it may not have.
    static func controlRefused(remote: Bool, allowed: Bool) -> String {
        guard remote else { return "Mac control is turned on at the Mac: choose Enable Mac Control in VisionDesk there." }
        return allowed ? "Control was stopped on the Mac. Choose Enable Mac Control there to resume."
                       : "The Mac is set to viewing only. Control can be allowed in VisionDesk on the Mac."
    }
}
