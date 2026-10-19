import DeskCore
import DeskTransport
import Foundation
import Network

/// The Mac a session is with, and everything needed to dial it again without asking anyone. Held
/// in memory for the session only; the key reaches the Keychain exclusively through the model's
/// `rememberIfRequested`, after TLS has authenticated.
struct RetryTarget {
    /// How the session was started, which decides whether it can come back by itself and what a
    /// failure advises.
    enum Origin: Equatable {
        /// Chosen from the Macs found on this network.
        case nearby
        /// Dialled at a typed address.
        case typed
        /// Dialled from the saved Mac.
        case saved
    }

    let route: MacRoute
    let name: String
    let key: PairingKey
    let origin: Origin
    var shouldRemember: Bool
    /// True once a session with this target has authenticated in this app session.
    var hasLinked = false
    /// Whether the Mac keeps accepting this key, on a listener that stays up, once a session ends.
    /// A typed address reaches a Mac set up for remote access, and a saved Mac was saved because
    /// its pairing outlives sessions, so both start true. A Mac found on this network pairs for one
    /// session and then stops listening, so it starts false, and becomes true only when the Mac
    /// says so during the session; see `DeskClientModel.macKeepsPairing()`.
    var macKeepsPairing: Bool

    init(route: MacRoute, name: String, key: PairingKey, origin: Origin, shouldRemember: Bool) {
        self.route = route
        self.name = name
        self.key = key
        self.origin = origin
        self.shouldRemember = shouldRemember
        self.macKeepsPairing = origin != .nearby
    }

    var isSaved: Bool { origin == .saved }

    /// Whether a failed attempt is worth repeating on the bounded schedule. A Mac that does not
    /// keep its pairing has nothing to come back to: its listener is gone once a session ends. Of
    /// the rest, a target that authenticated has a link to lose. A saved Mac's key authenticated
    /// when it was saved — it is stored only after TLS succeeds — so its failed first attempt is
    /// most likely a Mac still waking, restarting sharing or waiting for its VPN. A typed or
    /// discovered key that never authenticated is not retried: that would repeat the same refusal
    /// five more times under a "lost the connection" message that is not true.
    var isRetryable: Bool { macKeepsPairing && (hasLinked || isSaved) }
}

struct NearbyMac: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// What this headset remembers about the one Mac it reconnects to without a key: its name and how
/// to reach it — a typed address, or its Bonjour service on this network — and nothing else. The
/// pairing key for it lives in the Keychain, never here, so these values are safe in ordinary
/// preferences.
struct RememberedMac: Equatable, Sendable {
    let name: String
    let route: MacRoute

    init(name: String, route: MacRoute) {
        self.name = name
        self.route = route
    }

    /// A Mac reached at a typed address, given as `RemoteMacAddress.formatted`.
    init(address: String, name: String) {
        self.init(name: name, route: .address(address))
    }

    /// The address of a Mac saved by address; nil for one saved by its service on this network.
    var address: String? {
        guard case let .address(text) = route else { return nil }
        return text
    }
}

extension RememberedMac: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case route
        case address
    }

    /// Reads a record of either age. One written before routes existed has only an address and a
    /// name. A route that is present but is not one the model could have made is not trusted.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        if let route = try? container.decodeIfPresent(MacRoute.self, forKey: .route), route.isValid {
            self.init(name: name, route: route)
        } else {
            self.init(address: try container.decode(String.self, forKey: .address), name: name)
        }
    }

    /// Writes the route, and for an address also the address on its own, which is all an older
    /// build of this app reads.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(route, forKey: .route)
        try container.encodeIfPresent(address, forKey: .address)
    }
}

/// Where non-secret connection metadata lives: the saved Mac, and the routes with a Stop the
/// Mac may never have read. Preferences in the app; tests inject memory or a throwaway suite
/// so a run leaves nothing behind on disk.
protocol RememberedMacStore: AnyObject {
    func load() -> RememberedMac?
    func save(_ mac: RememberedMac)
    /// Forgets the saved Mac. A pending Stop is not forgotten with it: it ends only when that
    /// Mac grants control again.
    func clear()
    /// See `DeskClientModel.stoppedRoutes`. Unreadable data reads as no routes.
    func loadStoppedRoutes() -> Set<MacRoute>
    /// Replaces the routes with a pending Stop. An empty set removes the record.
    func saveStoppedRoutes(_ routes: Set<MacRoute>)
}

/// Ordinary preferences. Only ever holds the saved Mac's name and route and the routes with a
/// pending Stop: a secret written here would be readable by anything that can read the app
/// container.
final class UserDefaultsRememberedMacStore: RememberedMacStore {
    static let rememberedMacKey = "org.visiondesk.VisionDesk.rememberedMac"
    static let stoppedRoutesKey = "org.visiondesk.VisionDesk.stoppedRoutes"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RememberedMac? {
        guard let data = defaults.data(forKey: Self.rememberedMacKey) else { return nil }
        return try? JSONDecoder().decode(RememberedMac.self, from: data)
    }

    func save(_ mac: RememberedMac) {
        guard let data = try? JSONEncoder().encode(mac) else { return }
        defaults.set(data, forKey: Self.rememberedMacKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.rememberedMacKey)
    }

    func loadStoppedRoutes() -> Set<MacRoute> {
        // A value of the wrong type reads as nil here, and malformed data as no routes.
        PendingStopsCodec.decode(defaults.data(forKey: Self.stoppedRoutesKey))
    }

    func saveStoppedRoutes(_ routes: Set<MacRoute>) {
        guard !routes.isEmpty else {
            defaults.removeObject(forKey: Self.stoppedRoutesKey)
            return
        }
        // Encoding a list of strings cannot fail; if it ever did, the last record is kept rather
        // than erased, so a pending Stop is never dropped by a write.
        guard let data = PendingStopsCodec.encode(routes) else { return }
        defaults.set(data, forKey: Self.stoppedRoutesKey)
    }
}

enum ScreenInteractionMode: String, CaseIterable, Identifiable {
    case pointer
    case interact
    case scroll
    var id: Self { self }
    var title: String {
        switch self { case .pointer: return "Pointer"; case .interact: return "Drag"; case .scroll: return "Scroll" }
    }
    var symbol: String {
        switch self { case .pointer: return "cursorarrow"; case .interact: return "hand.draw"; case .scroll: return "arrow.up.and.down" }
    }
    var instruction: String {
        switch self {
        case .pointer: return "Pinch and move to position the pointer, then tap to click at the pointer. Choose Drag to select or move items."
        case .interact: return "Pinch and move to drag with the Mac’s left button held."
        case .scroll: return "Pinch and move to scroll."
        }
    }
}
