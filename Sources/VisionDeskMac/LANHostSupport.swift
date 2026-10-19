import Foundation
import DeskTransport

/// Non-secret availability and owner decisions. No pairing credential enters preferences.
struct LANHostConfiguration: Equatable, Codable {
    var enabled = false
    var allowControl = false
    var ownerPaused = false
    var peerPaused = false
    static let disabled = LANHostConfiguration()
    private static let preference = "org.visiondesk.VisionDesk.lan-host-v1"
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: preference),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .disabled }
        return value
    }
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.preference) }
    }
}

enum LANHostKeychain {
    static let account = "mac.lan-v1"
    static func load() throws -> PairingKey? { try PairingKeyStore().load(account: account) }
    static func save(_ key: PairingKey) throws { try PairingKeyStore().save(key, account: account) }
}

/// Listener settings used by the actual server start and by isolated behavior checks.
struct HostListenerPlan {
    let key: PairingKey
    let port: UInt16?
    let bindHost: String?
    let name: String
    var allowsReconnect: Bool { true }
}
