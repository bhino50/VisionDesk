import Foundation
import Network

/// The nearby list, built from what discovery found: one entry per Mac.
///
/// Discovery can report one Mac once for each interface it was seen on — Wi-Fi and a
/// peer-to-peer link, for instance — and each of those endpoints names its interface. A Mac is
/// its Bonjour service (name, type and domain), the identity `MacRoute` also gives it, so it is
/// listed once, under an ID that does not change when the interface does. Of its endpoints, the
/// one least tied to a particular link is kept for dialling.
enum NearbyMacList {
    static func peers(from endpoints: [NWEndpoint]) -> [NearbyMac] {
        var best: [String: (rank: Int, mac: NearbyMac)] = [:]
        for endpoint in endpoints {
            // The browser only reports services; anything else names no Mac to pair with.
            guard case let .service(name, type, domain, interface) = endpoint else { continue }
            let id = [name, type, domain].joined(separator: "\u{1f}")
            let rank = Self.rank(of: interface)
            if let kept = best[id], kept.rank <= rank { continue }
            best[id] = (rank, NearbyMac(id: id, name: name, endpoint: endpoint))
        }
        return best.values.map { $0.mac }.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// The Mac to keep chosen: the current one while it is listed, and also while the list is
    /// empty, because discovery restarting is not the wearer choosing again. Otherwise the first.
    static func selection(keeping current: String?, in peers: [NearbyMac]) -> String? {
        guard !peers.isEmpty else { return current }
        if let current, peers.contains(where: { $0.id == current }) { return current }
        return peers.first?.id
    }

    /// Lower is preferred. An endpoint bound to no interface lets the system choose the path;
    /// then wired, then Wi-Fi. Peer-to-peer links report as other interfaces and come last.
    private static func rank(of interface: NWInterface?) -> Int {
        guard let interface else { return 0 }
        switch interface.type {
        case .wiredEthernet: return 1
        case .wifi: return 2
        case .loopback: return 3
        case .cellular: return 4
        case .other: return 5
        @unknown default: return 6
        }
    }
}
