import Foundation
import Network
import DeskCore

/// A start request that cannot be honored. Reported before any listener binds,
/// so a bad argument never disturbs a session that is already running.
public enum DeskServerError: Error, Equatable, Sendable, LocalizedError {
    /// Port 0 asks the system for any free port, which a remote device cannot
    /// guess. Pass `nil` when that is what the caller actually wants.
    case invalidPort

    public var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Port 0 is not a usable listening port. Leave the port blank to pick one automatically, or enter a port between 1 and 65535."
        }
    }
}

@MainActor
public final class DeskServer {
    public var onConnection: ((DeskConnection) -> Void)?
    public var onStatus: ((String) -> Void)?
    /// A terminal listener failure. A normal stop or authenticated connection does not invoke this.
    public var onStopped: ((String) -> Void)?
    public private(set) var port: UInt16?

    private var listener: NWListener?
    private var generation: UInt64 = 0
    private var pending: [ObjectIdentifier: DeskConnection] = [:]
    private var pendingOrder: [(id: ObjectIdentifier, admitted: TimeInterval)] = []
    private let minimumHandshakeResidency: TimeInterval = 1
    private var activeConnection: DeskConnection?
    /// Whether the current listener outlives an authenticated session.
    private var allowsReconnect = false
    private let maximumPendingHandshakes = 4
    private let handshakeTimeout: TimeInterval
    private let frameTimeout: TimeInterval
    private let idleTimeout: TimeInterval
    var pendingHandshakeCount: Int { pending.count }
    /// The Bonjour name the current listener advertises, or nil when it advertises nothing.
    var advertisedServiceName: String? { listener?.service?.name }
    /// Whether the OS admits only local-link peers to the current listener.
    var acceptsLocalLinkOnly: Bool { listener?.parameters.acceptLocalOnly ?? false }

    public init() {
        handshakeTimeout = 10
        frameTimeout = 10
        idleTimeout = 10
    }

    init(handshakeTimeout: TimeInterval, frameTimeout: TimeInterval = 10, idleTimeout: TimeInterval = 10) {
        precondition(handshakeTimeout > 0 && frameTimeout > 0 && idleTimeout > 0)
        self.handshakeTimeout = handshakeTimeout
        self.frameTimeout = frameTimeout
        self.idleTimeout = idleTimeout
    }

    /// Starts accepting one authenticated Vision Pro session.
    ///
    /// - Parameters:
    ///   - key: The pairing secret. Pass a freshly generated key for one-session
    ///     pairing, or a key loaded from `PairingKeyStore` to accept a device this
    ///     Mac already remembers.
    ///   - name: The Bonjour service name used for discovery on the local link.
    ///   - port: A fixed listening port, or `nil` to keep the current ephemeral
    ///     behavior. Pin a port whenever the headset dials this Mac by address
    ///     instead of finding it by Bonjour, because an ephemeral port changes on
    ///     every start and a remote device cannot guess it.
    ///   - allowReconnect: When `true` the listener stays bound through an
    ///     authenticated session and remains available after it ends, so a
    ///     remembered headset can come back without anyone touching this Mac.
    ///     Exactly one device is admitted at a time either way.
    ///
    /// Reaching this Mac from another network is the caller's job and is out of
    /// scope here: this listener binds a local port and nothing else. It opens no
    /// relay, forwards no port, and changes no VPN configuration.
    public func start(key: PairingKey, name: String, port: UInt16? = nil, allowReconnect: Bool = false, bindHost: String? = nil) throws {
        try start(key: key, serviceName: bindHost == nil ? serviceName(name) : nil, port: port, loopbackOnly: false, allowReconnect: allowReconnect, bindHost: bindHost)
    }

    /// Isolated diagnostics use the same authentication without exposing a LAN service.
    /// Internal rather than `package`: the Xcode project compiles these sources as plain
    /// frameworks without `-package-name`, and `@testable import` already reaches this.
    /// The bound port is published through `port`, as it is for any other start.
    func startLoopback(key: PairingKey, allowReconnect: Bool = false) throws {
        try start(key: key, serviceName: nil, port: nil, loopbackOnly: true, allowReconnect: allowReconnect)
    }

    private func start(key: PairingKey, serviceName: String?, port requestedPort: UInt16?, loopbackOnly: Bool, allowReconnect: Bool, bindHost: String? = nil) throws {
        // Validated before tear-down so a rejected argument leaves any running
        // session exactly as it was.
        if let requestedPort, requestedPort == 0 { throw DeskServerError.invalidPort }
        let generation = tearDown()
        guard generation == self.generation else { throw CancellationError() }
        let parameters = SecureParameters.make(key: key)
        if loopbackOnly {
            parameters.includePeerToPeer = false
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        }
        let boundPort = requestedPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        if let bindHost {
            parameters.includePeerToPeer = false
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: .any)
        }
        // Advertising is for headsets on this network, so an advertised listener admits local-link
        // peers only: a routed source, such as global IPv6 from outside the LAN, never reaches TLS.
        if serviceName != nil { parameters.acceptLocalOnly = true }
        let admission = HandshakeAdmission(bindHost: bindHost, loopbackOnly: loopbackOnly)
        let listener = try NWListener(using: parameters, on: boundPort)
        if let serviceName {
            listener.service = NWListener.Service(name: serviceName, type: SecureParameters.serviceType)
        }
        self.listener = listener
        allowsReconnect = allowReconnect
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.listener != nil else { return }
                switch state {
                case .ready:
                    self.port = self.listener?.port?.rawValue
                    self.onStatus?(allowReconnect
                        ? "Available for the remembered Vision Pro to connect."
                        : "Available for pairing.")
                case .waiting(let error):
                    // Not terminal: Network.framework keeps trying, so this only explains the wait.
                    self.onStatus?(ListenerProblem.waitingStatus(error, port: requestedPort, bindHost: bindHost))
                case .failed(let error):
                    self.listenerFailed(ListenerProblem.failureStatus(error, port: requestedPort, bindHost: bindHost))
                case .setup, .cancelled:
                    break
                @unknown default:
                    self.listenerFailed("The local listener entered an unsupported state.")
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                // The active-session check is what refuses a second device while
                // one is connected, which is the only guard left in reconnect mode.
                guard let self, self.generation == generation, self.listener != nil,
                      self.activeConnection == nil,
                      admission.admits(peerHost: HandshakeAdmission.host(of: connection.endpoint),
                                       pendingHosts: self.pending.values.map(\.endpointHost)) else {
                    connection.cancel()
                    return
                }
                // A stalled collection of different sources cannot monopolize all slots.
                // Each admitted peer gets a protected TLS progress window; at capacity,
                // rotate the oldest eligible handshake. This bounds cancellation churn
                // without an arrival-rate gate that could also lock out a valid peer.
                self.pendingOrder.removeAll { self.pending[$0.id] == nil }
                if self.pending.count >= self.maximumPendingHandshakes {
                    guard let oldest = self.pendingOrder.first,
                          ProcessInfo.processInfo.systemUptime - oldest.admitted >= self.minimumHandshakeResidency,
                          let evicted = self.pending.removeValue(forKey: oldest.id) else {
                        connection.cancel()
                        return
                    }
                    self.pendingOrder.removeFirst()
                    evicted.stateObserver = nil
                    evicted.cancel()
                }
                self.beginHandshake(connection, generation: generation)
            }
        }
        listener.start(queue: .main)
    }

    /// Cancels the listener and any session, then clears the callbacks so a
    /// stopped server can never deliver a late connection or status. Assign the
    /// callbacks again before the next `start`.
    public func stop() {
        let generation = tearDown()
        // The final status is delivered before the callbacks are released, so the
        // caller still sees why its server went quiet.
        if generation == self.generation { onStatus?("Stopped.") }
        onConnection = nil
        onStatus = nil
        onStopped = nil
    }

    @discardableResult
    private func tearDown() -> UInt64 {
        generation &+= 1
        let generation = self.generation
        stopListening()
        allowsReconnect = false
        let connections = Array(pending.values) + (activeConnection.map { [$0] } ?? [])
        pending.removeAll()
        pendingOrder.removeAll()
        activeConnection = nil
        for connection in connections {
            connection.stateObserver = nil
            connection.cancel()
        }
        return generation
    }

    private func listenerFailed(_ reason: String) {
        let generation = tearDown()
        guard generation == self.generation else { return }
        onStatus?(reason)
        guard generation == self.generation else { return }
        onStopped?(reason)
    }

    private func beginHandshake(_ connection: NWConnection, generation: UInt64) {
        let channel = DeskConnection(connection: connection, handshakeTimeout: handshakeTimeout, frameTimeout: frameTimeout, idleTimeout: idleTimeout)
        let id = ObjectIdentifier(channel)
        pending[id] = channel
        pendingOrder.append((id, ProcessInfo.processInfo.systemUptime))
        channel.stateObserver = { [weak self, weak channel] state in
            guard let self, let channel, self.generation == generation else { return }
            switch state {
            case .ready:
                guard self.pending.removeValue(forKey: id) != nil, self.activeConnection == nil else {
                    channel.cancel()
                    return
                }
                self.activeConnection = channel
                // One-session pairing consumes its listener. A remembered device
                // keeps it bound, so the session can end and resume on its own.
                if !self.allowsReconnect { self.stopListening() }
                let otherHandshakes = Array(self.pending.values)
                self.pending.removeAll()
                self.pendingOrder.removeAll()
                for other in otherHandshakes {
                    other.stateObserver = nil
                    other.cancel()
                }
                self.onStatus?("Secure connection established.")
                guard self.generation == generation, self.activeConnection === channel else { return }
                self.onConnection?(channel)
            case .disconnected:
                self.pending.removeValue(forKey: id)
                if self.activeConnection === channel {
                    self.activeConnection = nil
                    self.onStatus?(self.allowsReconnect
                        ? "Disconnected. Waiting for the remembered Vision Pro to reconnect."
                        : "Disconnected. Start pairing to reconnect.")
                }
            case .connecting:
                break
            }
        }
        channel.start()
    }

    private func stopListening() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func serviceName(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "VisionDesk Mac" }
        while name.utf8.count > 63 { name.removeLast() }
        return name
    }
}

/// Which unauthenticated connections a listener lets start a handshake. Authentication is still
/// PSK-TLS; this only decides who may occupy one of the four handshake slots before it completes.
///
/// One unauthenticated slot per source used to be a tailnet-only rule. A remembered listener on
/// this network now stays up for as long as the Mac shares, so the rule covers every listener
/// another device can reach: otherwise one device could hold all four slots and keep the
/// remembered headset out indefinitely. Loopback listeners keep accepting any number, which the
/// diagnostics and the transport tests rely on. Pure, so every rule is checked without a socket.
struct HandshakeAdmission: Equatable {
    /// Explicit private-address bindings refuse public, loopback and link-local sources.
    let requiresPrivatePeer: Bool
    /// A source may hold only one unauthenticated slot at a time.
    let limitsPerSource: Bool

    init(bindHost: String?, loopbackOnly: Bool) {
        let boundAddress = bindHost.flatMap { RemoteMacAddress(host: $0) }
        requiresPrivatePeer = boundAddress?.isPrivateIP == true
        limitsPerSource = !loopbackOnly && !(bindHost.map(Self.isLoopback) ?? false)
    }

    /// `peerHost` is the source of the new connection; `pendingHosts` are the sources of the
    /// handshakes already in progress. A source that cannot be named is refused wherever sources count.
    func admits(peerHost: String?, pendingHosts: [String?]) -> Bool {
        if requiresPrivatePeer {
            guard let peerHost, RemoteMacAddress(host: peerHost)?.isPrivateIP == true else { return false }
        }
        guard limitsPerSource else { return true }
        guard let peerHost else { return false }
        let canonicalPeer = RemoteMacAddress(host: peerHost)?.host ?? peerHost
        return !pendingHosts.contains { source in
            guard let source else { return false }
            return (RemoteMacAddress(host: source)?.host ?? source) == canonicalPeer
        }
    }

    static func host(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        return String(describing: host)
    }

    static func isLoopback(_ host: String) -> Bool {
        let canonical = RemoteMacAddress(host: host)?.host ?? host.lowercased()
        let octets = canonical.split(separator: ".", omittingEmptySubsequences: false)
        let ipv4Loopback = octets.count == 4 && octets.allSatisfy { UInt8($0) != nil } && octets[0] == "127"
        return ipv4Loopback || canonical == "::1" || canonical == "localhost"
    }
}

/// Why a listener cannot accept connections, explained for the person at this Mac.
///
/// Network.framework reports the reason with the state it enters. These messages used to ignore
/// it and blame another app for every failure on a pinned port, including a remote host whose
/// Tailscale address had gone: the port was free, and the advice named a port field this app does
/// not have. Now the port-in-use explanation is kept for `EADDRINUSE`, a missing bind address is
/// named as such, and anything unrecognized carries the system's own reason.
///
/// Pure, so every branch is checked without binding a socket.
enum ListenerProblem: Equatable {
    /// `EADDRINUSE`: another socket on this Mac already holds the port.
    case portInUse
    /// `EADDRNOTAVAIL`: the address to listen on is not on this Mac, such as a Tailscale address
    /// while Tailscale is disconnected, or an address that belongs to another device.
    case addressUnavailable
    /// The network the address belongs to is down or unreachable.
    case networkDown
    /// The local network privacy policy refused the Bonjour service.
    case localNetworkDenied
    /// macOS refused the operation for this process.
    case notPermitted
    /// Anything else. Its message carries the system's own reason.
    case other

    /// `kDNSServiceErr_PolicyDenied`, which local network privacy reports for Bonjour.
    static let dnsPolicyDenied: Int32 = -65570

    init(_ error: NWError?) {
        switch error {
        case .posix(let code)?:
            switch code {
            case .EADDRINUSE: self = .portInUse
            case .EADDRNOTAVAIL: self = .addressUnavailable
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH: self = .networkDown
            case .EACCES, .EPERM: self = .notPermitted
            default: self = .other
            }
        case .dns(let code)? where code == Self.dnsPolicyDenied:
            self = .localNetworkDenied
        default:
            self = .other
        }
    }

    /// The terminal message, delivered once through `onStatus` and `onStopped`.
    static func failureStatus(_ error: NWError?, port: UInt16?, bindHost: String?) -> String {
        let place = location(port: port, bindHost: bindHost)
        guard let error else { return "Could not listen on \(place). Check this Mac's network connection." }
        let reason = systemReason(error)
        switch (ListenerProblem(error), bindHost, port) {
        case (.portInUse, _, .some):
            return "Could not listen on \(place): another app on this Mac is already using that port (\(reason)). Quit that app to free the port."
        case (.addressUnavailable, let host?, _):
            return "Could not listen on \(place): that address is not on this Mac right now (\(reason)). \(addressAdvice(host))"
        case (.addressUnavailable, nil, _):
            return "Could not listen on \(place): this Mac has no usable network address (\(reason)). Check this Mac's network connection."
        case (.networkDown, let host?, _):
            return "Could not listen on \(place): its network is unavailable (\(reason)). \(addressAdvice(host))"
        case (.networkDown, nil, _):
            return "Could not listen on \(place): the network is unavailable (\(reason)). Check this Mac's network connection."
        case (.localNetworkDenied, _, _):
            return "Could not listen on \(place): VisionDesk is not allowed to use the local network (\(reason)). \(localNetworkAdvice)"
        case (.notPermitted, _, _):
            return "Could not listen on \(place): macOS did not allow it (\(reason)). \(localNetworkAdvice)"
        case (.portInUse, _, nil), (.other, _, _):
            return "Could not listen on \(place) (\(reason)). Check this Mac's network connection."
        }
    }

    /// A listener in `.waiting` is still trying, so this explains the wait without ending anything.
    static func waitingStatus(_ error: NWError?, port: UInt16?, bindHost: String?) -> String {
        guard let error else { return "Waiting for the network to become available." }
        let reason = systemReason(error)
        switch (ListenerProblem(error), bindHost, port) {
        case (.portInUse, _, .some):
            return "Waiting for \(location(port: port, bindHost: bindHost)): another app on this Mac is using that port (\(reason)). Quit that app to free the port."
        case (.addressUnavailable, let host?, _), (.networkDown, let host?, _):
            return "Waiting for \(canonical(host)) to be available on this Mac (\(reason)). \(addressAdvice(host))"
        case (.addressUnavailable, nil, _), (.networkDown, nil, _):
            return "Waiting for a network connection (\(reason))."
        case (.localNetworkDenied, _, _), (.notPermitted, _, _):
            return "Waiting for access to the local network (\(reason)). \(localNetworkAdvice)"
        case (.portInUse, _, nil), (.other, _, _):
            return "Waiting to listen on \(location(port: port, bindHost: bindHost)) (\(reason))."
        }
    }

    /// What was being listened on, as the person at this Mac would recognize it.
    static func location(port: UInt16?, bindHost: String?) -> String {
        switch (bindHost, port) {
        case let (host?, port?): return RemoteMacAddress(host: host, port: port)?.formatted ?? "\(host) port \(port)"
        case let (host?, nil): return canonical(host)
        case let (nil, port?): return "port \(port)"
        case (nil, nil): return "the local network"
        }
    }

    /// The system's own words for the error, so a cause not recognized here is still reported.
    static func systemReason(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return String(cString: strerror(code.rawValue))
        case .dns(let code): return "DNS service error \(code)"
        case .tls(let status): return "TLS error \(status)"
        default: return String(describing: error)
        }
    }

    private static let localNetworkAdvice = "Allow VisionDeskMac in System Settings → Privacy & Security → Local Network."

    /// A bound address that is missing is most often a Tailscale address whose tunnel is down.
    private static func addressAdvice(_ host: String) -> String {
        let address = canonical(host)
        return RemoteMacAddress(host: host)?.isTailnetIPv4 == true
            ? "Check that Tailscale is connected on this Mac and that \(address) is this Mac's Tailscale address."
            : "Check that \(address) is this Mac's address and that its network is connected."
    }

    private static func canonical(_ host: String) -> String { RemoteMacAddress(host: host)?.host ?? host }
}
