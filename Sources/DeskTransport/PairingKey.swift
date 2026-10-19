import Foundation
import Network
import Security

/// A 128-bit pairing secret shared by this Mac and one Vision Pro. It is the TLS
/// pre-shared key for the session, so whoever holds it can take a session.
///
/// Two lifetimes are supported, and the caller picks one per start:
///
/// - One-session pairing: generate a new key for every session and never retain
///   it. This is still the default, and `DeskServer.start` consumes its listener
///   on authentication to match.
/// - Remembered pairing: retain exactly one key per saved Mac through
///   `PairingKeyStore`, which keeps it in this device's Keychain. Retaining the
///   key is what lets a headset reconnect unattended — after a dropped link, a
///   sleep, or from another network over a VPN the owner already runs — without
///   anyone reading a fresh key off the Mac's screen. Remembering a key does not
///   widen the trust boundary in any other way: the same single PSK-authenticated
///   TLS session is all that is ever established.
///
/// The redacted `description`, `debugDescription`, and `customMirror` below are
/// the only representations reflection or logging can reach, in either lifetime.
public struct PairingKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let bytes: [UInt8]

    public static func generate() -> PairingKey {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            preconditionFailure("Secure random generation is unavailable.")
        }
        return PairingKey(bytes: bytes)
    }

    public init?(string: String) {
        // Only ASCII hexadecimal, separators, and whitespace are accepted.
        let digits = string.unicodeScalars.filter { $0 != "-" && !CharacterSet.whitespacesAndNewlines.contains($0) }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard digits.count == 32, digits.allSatisfy({ hexadecimal.contains($0) }) else { return nil }
        let characters = Array(String(String.UnicodeScalarView(digits)))
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes: bytes)
    }

    /// Display only in the pairing UI; do not persist or log this value.
    /// Remembered pairing does not change that: `PairingKeyStore` writes the raw
    /// secret and never this formatting, so nothing turns a UI string into a
    /// storage format.
    public var displayValue: String {
        bytes.enumerated().map { index, byte in
            (index > 0 && index.isMultiple(of: 2) ? "-" : "") + String(format: "%02X", byte)
        }.joined()
    }

    public var description: String { "PairingKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    /// The raw secret, for `PairingKeyStore` only.
    ///
    /// Internal on purpose: nothing outside this module can read the bytes, and
    /// the redacted descriptions above stay the only representation reachable by
    /// logging, reflection, or a crash report. This exists because a remembered
    /// key has to reach the Keychain somehow, and routing it through `displayValue`
    /// would turn a UI string into a persistence format.
    var keychainSecret: Data { Data(bytes) }

    /// Rebuilds a key from the payload written by `keychainSecret`. Returns nil
    /// for anything that is not a 128-bit secret, so a foreign or corrupt Keychain
    /// item is reported to the caller instead of being used as a key.
    init?(keychainSecret: Data) {
        guard keychainSecret.count == 16 else { return nil } // 128 bits, as generate() produces
        self.init(bytes: [UInt8](keychainSecret))
    }

    fileprivate var dispatchData: DispatchData {
        bytes.withUnsafeBytes { DispatchData(bytes: $0) }
    }
}

@MainActor
enum SecureParameters {
    static let serviceType = "_visiondesk._tcp"
    static let applicationProtocol = "visiondesk/1"

    static func make(key: PairingKey) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3

        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let identity = Data("VisionDesk.v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key.dispatchData as __DispatchData, identity as __DispatchData)
        // TN3213: Network.framework external PSKs require TLS 1.2 and NWConnection.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_false_start_enabled(options, false)
        sec_protocol_options_add_tls_application_protocol(options, applicationProtocol)

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    static func isAuthenticated(_ connection: NWConnection) -> Bool {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
        let metadata = tls.securityProtocolMetadata
        guard sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata) == .TLSv12,
              sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata).rawValue == TLS_PSK_WITH_AES_128_GCM_SHA256,
              let protocolName = sec_protocol_metadata_get_negotiated_protocol(metadata) else { return false }
        return String(cString: protocolName) == applicationProtocol
    }
}
