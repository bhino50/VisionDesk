import DeskCore
import Foundation
import Network

/// How a session reached its Mac, which is how a pending Stop recognizes that Mac again.
///
/// Connection metadata of the same kind as the saved Mac's address and label, and nothing
/// secret: no key and no code is ever part of it. That is what lets it live in ordinary
/// preferences.
enum MacRoute: Hashable, Codable, Sendable {
    /// An address and port in `RemoteMacAddress.formatted` form, so every way of writing one
    /// address — typed, saved, or a host-and-port endpoint — is one route.
    case address(String)
    /// A discovered (Bonjour) service. The interface it happened to be found on is not part of
    /// it, so the same service found over another interface is the same route. A service and
    /// an address are never the same route.
    case service(name: String, type: String, domain: String)

    /// Bounds what is read back from preferences. Real service fields are far shorter.
    private static let maximumFieldBytes = 255

    init(_ address: RemoteMacAddress) {
        self = .address(address.formatted)
    }

    /// The route of an endpoint the model was handed directly. Nil for an endpoint that names
    /// neither a dialable address nor a service, which no Mac is reached by.
    init?(_ endpoint: NWEndpoint) {
        switch endpoint {
        case let .service(name, type, domain, _):
            self = .service(name: name, type: type, domain: domain)
        case let .hostPort(host, port):
            guard let address = RemoteMacAddress(host: Self.text(of: host), port: port.rawValue) else { return nil }
            self = .address(address.formatted)
        default:
            return nil
        }
    }

    /// What to dial to reach this Mac again. A service is resolved by the system when the
    /// connection starts, on whichever interface reaches it. Nil for an address that no longer
    /// parses, which no route the model made can be.
    var endpoint: NWEndpoint? {
        switch self {
        case let .address(text):
            guard let address = RemoteMacAddress(string: text),
                  let port = NWEndpoint.Port(rawValue: address.port) else { return nil }
            return .hostPort(host: NWEndpoint.Host(address.host), port: port)
        case let .service(name, type, domain):
            return .service(name: name, type: type, domain: domain, interface: nil)
        }
    }

    /// Whether this is a route the model could have made: a canonical address, or a service
    /// with bounded fields and a name and type. Anything else read from preferences is dropped.
    var isValid: Bool {
        switch self {
        case let .address(text):
            return RemoteMacAddress(string: text)?.formatted == text
        case let .service(name, type, domain):
            return !name.isEmpty && !type.isEmpty
                && [name, type, domain].allSatisfy { $0.utf8.count <= Self.maximumFieldBytes }
        }
    }

    private static func text(of host: NWEndpoint.Host) -> String {
        switch host {
        case let .name(name, _): return name
        case let .ipv4(address): return address.rawValue.map { String($0) }.joined(separator: ".")
        case let .ipv6(address): return "\(address)"
        @unknown default: return "\(host)"
        }
    }
}

/// The preference-store form of the routes with a pending Stop: a JSON list of routes, and
/// never a key or a code.
///
/// Reading is defensive, because preferences sit outside this app's control between launches.
/// Data that is too large or is not a JSON list reads as no routes. Inside a list, an entry that
/// does not decode, or is not a valid route, is dropped and the rest are kept. Nothing read here
/// can stop the app.
enum PendingStopsCodec {
    static let maximumRoutes = 64
    static let maximumBytes = 64 * 1_024

    static func encode(_ routes: Set<MacRoute>) -> Data? {
        // Routes and keys both sorted, so the same routes are always written as the same bytes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(routes.filter(\.isValid).sorted { "\($0)" < "\($1)" })
    }

    static func decode(_ data: Data?) -> Set<MacRoute> {
        guard let data, data.count <= maximumBytes,
              let entries = try? JSONDecoder().decode([Entry?].self, from: data) else { return [] }
        return Set(entries.lazy.compactMap { $0?.route }.filter(\.isValid).prefix(maximumRoutes))
    }

    /// One list entry, decoded on its own so a malformed one costs only itself.
    private struct Entry: Decodable {
        let route: MacRoute?

        init(from decoder: Decoder) throws {
            route = try? decoder.singleValueContainer().decode(MacRoute.self)
        }
    }
}
