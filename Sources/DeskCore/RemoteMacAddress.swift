// A remembered address for the Mac that hosts a VisionDesk session.
//
// Parsing here is purely textual. It never resolves DNS, never opens a socket,
// and never reports anything about a VPN. A 100.64.0.0/10 address or a `.ts.net`
// name only *looks* like Tailscale; whether that tunnel is actually up is
// observable only by connecting, so nothing in this file claims it. Callers build
// their own Network endpoint from the parsed `host` and `port`.

import Foundation

public struct RemoteMacAddress: Sendable, Equatable {
    /// The port VisionDesk pins when a headset dials this Mac by address.
    /// An ephemeral port changes on every start and a remembered device cannot
    /// guess it, so unattended reconnection needs a fixed one.
    public static let defaultPort: UInt16 = 58_271

    /// RFC 1035 limit for a host name in presentation form.
    private static let maximumHostLength = 253
    /// RFC 1035 limit for one label.
    private static let maximumLabelLength = 63
    /// Bounds the work done on untrusted text before anything else runs.
    private static let maximumInputLength = 300
    /// Addresses that are syntactically valid but cannot be dialed.
    private static let undialableHosts: Set<String> = ["0.0.0.0", "::"]

    /// Lowercased canonical presentation form. IPv6 literals carry no brackets.
    public let host: String
    public let port: UInt16

    /// Builds an address from separate parts. An IPv6 literal may arrive bare or
    /// bracketed; a host name must not carry a port.
    public init?(host: String, port: UInt16 = RemoteMacAddress.defaultPort) {
        guard port != 0 else { return nil }
        var candidate = host
        if candidate.hasPrefix("["), candidate.hasSuffix("]") {
            candidate = String(candidate.dropFirst().dropLast())
        }
        guard let canonical = Self.canonicalHost(candidate) else { return nil }
        self.host = canonical
        self.port = port
    }

    /// Parses `host`, `host:port`, `[ipv6]`, or `[ipv6]:port`.
    ///
    /// Accepts Tailscale IPv4 addresses, MagicDNS names, ordinary LAN names such
    /// as `mac-mini.local`, and bracketed IPv6. Rejects schemes, paths, embedded
    /// credentials, line breaks, inner whitespace, non-ASCII text, port 0, and a
    /// bare IPv6 literal, whose colons cannot be told apart from a port.
    public init?(string: String) {
        guard let text = Self.sanitized(string) else { return nil }
        let hostText: String
        let portText: String?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let literal = String(text[text.index(after: text.startIndex)..<close])
            let rest = String(text[text.index(after: close)...])
            // Brackets exist to disambiguate IPv6 colons; nothing else may use them.
            guard literal.contains(":") else { return nil }
            if rest.isEmpty {
                portText = nil
            } else {
                guard rest.hasPrefix(":") else { return nil }
                portText = String(rest.dropFirst())
            }
            hostText = literal
        } else {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            switch parts.count {
            case 1:
                hostText = text
                portText = nil
            case 2:
                hostText = String(parts[0])
                portText = String(parts[1])
            default:
                return nil
            }
        }
        guard let canonical = Self.canonicalHost(hostText) else { return nil }
        let resolvedPort: UInt16
        if let portText {
            guard let value = Self.parsePort(portText) else { return nil }
            resolvedPort = value
        } else {
            resolvedPort = Self.defaultPort
        }
        self.host = canonical
        self.port = resolvedPort
    }

    /// Canonical IPv4 in the address range Tailscale assigns to nodes.
    /// This is syntax and policy, not evidence that a tunnel is running.
    public var isTailnetIPv4: Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return false }
        return octets[0] == "100" && (64...127).contains(Int(octets[1])!)
    }

    /// Round-trips through `init?(string:)`. The port is always shown, so the
    /// value a remote headset will actually dial is never implied.
    public var formatted: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Trims only ASCII spaces and tabs at the ends, then requires every
    /// remaining byte to be printable ASCII. Line breaks, inner whitespace, and
    /// non-ASCII text are rejected rather than normalized.
    private static func sanitized(_ string: String) -> String? {
        guard string.utf8.count <= maximumInputLength else { return nil }
        let text = string.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !text.isEmpty, text.utf8.allSatisfy(isPrintableASCII) else { return nil }
        return text
    }

    /// Decimal only, bounded, no leading zero, and never port 0.
    private static func parsePort(_ text: String) -> UInt16? {
        guard (1...5).contains(text.utf8.count),
              text.utf8.allSatisfy(isDigit),
              text.first != "0",
              let value = UInt16(text), value != 0 else { return nil }
        return value
    }

    private static func canonicalHost(_ host: String) -> String? {
        guard !host.isEmpty, host.utf8.count <= maximumHostLength,
              host.utf8.allSatisfy(isPrintableASCII) else { return nil }
        let lowered = host.lowercased()
        // Colons never appear in a host name, so a colon means IPv6 or nothing.
        if lowered.contains(":") {
            return dialable(canonicalAddress(lowered, family: AF_INET6))
        }
        if let address = canonicalAddress(lowered, family: AF_INET) {
            guard address == lowered else { return nil }
            return dialable(address)
        }
        return canonicalDomainName(lowered)
    }

    /// Rejects the unspecified address, which parses but cannot be dialed.
    private static func dialable(_ address: String?) -> String? {
        guard let address, !undialableHosts.contains(address) else { return nil }
        return address
    }

    /// Validates an IP literal and returns its canonical text, so differently
    /// written forms of one address compare equal. Neither call touches DNS.
    private static func canonicalAddress(_ text: String, family: Int32) -> String? {
        var packed = [UInt8](repeating: 0, count: 16)
        let parsed = packed.withUnsafeMutableBytes { inet_pton(family, text, $0.baseAddress) }
        guard parsed == 1 else { return nil }
        var printable = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return packed.withUnsafeBytes { address in
            printable.withUnsafeMutableBufferPointer { output -> String? in
                guard let result = inet_ntop(family, address.baseAddress, output.baseAddress, socklen_t(output.count)) else { return nil }
                return String(cString: result)
            }
        }
    }

    /// RFC 1123 host syntax, bounded. The final label may not be all digits, so
    /// a truncated or mistyped address cannot slip through as a host name.
    private static func canonicalDomainName(_ host: String) -> String? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...maximumLabelLength).contains(label.utf8.count),
                  label.utf8.allSatisfy(isHostByte),
                  label.first != "-", label.last != "-" else { return nil }
        }
        guard let last = labels.last, !last.utf8.allSatisfy(isDigit) else { return nil }
        return host
    }

    private static func isPrintableASCII(_ byte: UInt8) -> Bool { (0x21...0x7E).contains(byte) }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    /// Lowercase letters, digits, and hyphen. The host is lowercased first.
    private static func isHostByte(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte) || isDigit(byte) || byte == 0x2D
    }
}
