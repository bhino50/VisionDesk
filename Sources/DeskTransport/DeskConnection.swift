import Foundation
import Network
import DeskCore

public enum DeskLinkState: Equatable, Sendable {
    case connecting
    case ready
    case disconnected(String)
}

/// An authenticated, single-use channel. All callbacks are serialized on the main actor.
@MainActor
public final class DeskConnection {
    public var onMessage: ((DeskMessage) -> Void)?
    public var onState: ((DeskLinkState) -> Void)?

    private let connection: NWConnection
    private let handshakeTimeout: TimeInterval
    private let frameTimeout: TimeInterval
    private let idleTimeout: TimeInterval?
    private var hasStarted = false
    private var isReady = false
    private var isStopped = false
    private var deadline: DispatchWorkItem?
    private var frameDeadline: DispatchWorkItem?
    private var idleDeadline: DispatchWorkItem?
    private var idleGeneration: UInt64 = 0
    private var frameGeneration: UInt64 = 0
    private var messageDecodeTask: Task<Void, Never>?
    public private(set) var pendingBytes = 0
    public private(set) var droppedFrameCount: UInt64 = 0
    private let maximumPendingBytes: Int
    private let controlReserveBytes = 65_536
    // Screen content should drop while it is still near live, not accumulate seconds of video.
    private let maximumScreenPendingBytes = 512 * 1_024
    /// Capacity is reserved for every display slot the protocol allows, whether or not it is
    /// streaming, so a display that starts late never has to win its share back from the others.
    static let maximumSharedDisplays = DeskMessage.maximumSharedDisplays
    private var screenPendingBytes = 0
    private var screenPendingByDisplay: [UInt32: Int] = [:]
    /// True once the peer has advertised `DeskMessage.binaryWireFormat`. This gates only what this
    /// side may send, so a session starts as pure JSON and is only ever upgraded from there.
    public private(set) var isUsingBinaryWireFormat = false
    /// True once this side has advertised the binary format. This gates only what it may receive,
    /// mirroring the sender's rule so a peer cannot use a format it was never offered.
    private var didAdvertiseBinary = false
    /// At most one capabilities message leaves this side per connection, so an advertisement and
    /// an acknowledgement can never go on answering each other.
    private var hasSentCapabilities = false
    // The server's lifecycle observer is independent of the application's callbacks.
    var stateObserver: ((DeskLinkState) -> Void)?

    public convenience init(endpoint: NWEndpoint, key: PairingKey) {
        // Only the headset sends periodic heartbeats. A paused Mac screen is
        // handled by freshness gating, not an inbound-idle disconnect on the client.
        self.init(connection: NWConnection(to: endpoint, using: SecureParameters.make(key: key)), idleTimeout: nil)
    }

    init(connection: NWConnection, handshakeTimeout: TimeInterval = 10, frameTimeout: TimeInterval = 10, idleTimeout: TimeInterval? = 10, maximumPendingBytes: Int = 8 * 1_024 * 1_024) {
        precondition(maximumPendingBytes > 65_536 && handshakeTimeout > 0 && frameTimeout > 0 && (idleTimeout == nil || idleTimeout! > 0))
        self.connection = connection
        self.handshakeTimeout = handshakeTimeout
        self.frameTimeout = frameTimeout
        self.idleTimeout = idleTimeout
        self.maximumPendingBytes = maximumPendingBytes
    }

    public func start() {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isReady else { return }
                self.finish("Pairing timed out. Check the key and local network.")
            }
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + handshakeTimeout, execute: deadline)
        publish(.connecting)
        guard !isStopped else { return }
        connection.start(queue: .main)
    }

    /// Returns false for a dropped video frame, closed channel, or invalid message.
    /// The bounded control reserve avoids placing input behind an unlimited video queue.
    @discardableResult
    public func send(_ message: DeskMessage) -> Bool {
        guard isReady, !isStopped else { return false }
        let outgoing = advertising(message)
        // Compressed video is screen content on exactly the same terms as a JPEG frame: it is
        // droppable, it is bounded by the same queue, and it never reaches into the control
        // reserve. Everything else is control and must not be silently discarded.
        let isScreenContent = outgoing.kind == "frame" || outgoing.kind == "video"
        let frame: Data
        do {
            // Screen content skips base64 and JSON once the peer has said it accepts a binary
            // body. Control stays JSON on every connection: it is small, its decode is inline,
            // and keeping one format for it means negotiation can never strand a command. This is
            // a narrower test than `isScreenContent`, which governs queueing: a frame the binary
            // header cannot represent exactly is still droppable screen content, sent as JSON.
            frame = isUsingBinaryWireFormat && FrameCodec.supportsBinaryBody(outgoing)
                ? try FrameCodec.encodeBinary(outgoing)
                : try FrameCodec.encode(outgoing)
        } catch {
            // Invalid local capture output must not terminate an otherwise healthy stream.
            return false
        }
        let displayID = outgoing.displayID ?? 0
        let limit = isScreenContent ? maximumPendingBytes - controlReserveBytes : maximumPendingBytes
        guard frame.count <= limit - pendingBytes,
              !isScreenContent || admitsScreenContent(frame.count, displayID: displayID) else {
            if isScreenContent {
                droppedFrameCount &+= 1
            } else {
                // Failing closed lets the receiver release any held mouse button.
                finish("The connection is too slow for control. Reconnect and try again.")
            }
            return false
        }
        // Recorded only once the frame is committed to the queue, so a dropped or refused
        // advertisement never leaves this side believing the peer was told something.
        if outgoing.kind == "capabilities" {
            hasSentCapabilities = true
            didAdvertiseBinary = didAdvertiseBinary || outgoing.wireFormat == DeskMessage.binaryWireFormat
        }
        pendingBytes += frame.count
        if isScreenContent {
            screenPendingBytes += frame.count
            screenPendingByDisplay[displayID, default: 0] += frame.count
        }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, !self.isStopped else { return }
                // Clamped rather than asserted: a completion that somehow ran twice must not
                // leave a negative counter, which would silently widen every budget below.
                self.pendingBytes = max(0, self.pendingBytes - frame.count)
                if isScreenContent {
                    self.screenPendingBytes = max(0, self.screenPendingBytes - frame.count)
                    let remaining = max(0, self.screenPendingByDisplay[displayID, default: 0] - frame.count)
                    if remaining == 0 { self.screenPendingByDisplay.removeValue(forKey: displayID) }
                    else { self.screenPendingByDisplay[displayID] = remaining }
                }
                if error != nil { self.finish("The secure connection was interrupted.") }
            }
        })
        return true
    }

    /// The ceiling all screen content shares. Control keeps its reserve outside it.
    private var screenCeilingBytes: Int { maximumPendingBytes - controlReserveBytes }

    /// What one display may always queue, no matter what the other displays are doing.
    private var displayReservationBytes: Int { min(maximumScreenPendingBytes, screenCeilingBytes) }

    /// Capacity above the sum of every display's reservation. One access unit too large for a
    /// reservation may borrow from here; the reservations themselves are never borrowable.
    private var screenSurplusBytes: Int {
        max(0, screenCeilingBytes - displayReservationBytes * Self.maximumSharedDisplays)
    }

    /// Decides whether one screen frame may be queued.
    ///
    /// A keyframe can legitimately exceed a per-display reservation — the encoder's burst
    /// allowance permits it, and refusing it only provokes another, equally large keyframe. So a
    /// display whose own queue is empty may borrow the shared surplus for exactly one such frame.
    /// Only the bytes a display holds *above* its reservation count against that surplus, which
    /// is what keeps an oversize frame on one display from spending the capacity another display
    /// is entitled to: every display retains a full reservation even at the global ceiling.
    /// A display that has already borrowed is held to its reservation, so one large frame still
    /// cannot authorize a backlog queued behind it.
    private func admitsScreenContent(_ byteCount: Int, displayID: UInt32) -> Bool {
        let reservation = displayReservationBytes
        let displayPending = screenPendingByDisplay[displayID, default: 0]
        let borrowed = screenPendingByDisplay.values.reduce(0) { $0 + max(0, $1 - reservation) }
        let allowance = displayPending == 0
            ? reservation + max(0, screenSurplusBytes - borrowed)
            : reservation
        return byteCount <= allowance - displayPending
            && byteCount <= screenCeilingBytes - screenPendingBytes
    }

    /// Cancels immediately. The receiver must release input when the channel closes.
    var endpointHost: String? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        return String(describing: host)
    }

    public func cancel() {
        finish("Disconnected.")
    }

    private func handle(_ state: NWConnection.State) {
        guard !isStopped else { return }
        switch state {
        case .ready:
            guard !isReady else { return }
            guard SecureParameters.isAuthenticated(connection) else {
                finish("The connection did not negotiate the required security.")
                return
            }
            isReady = true
            deadline?.cancel()
            deadline = nil
            publish(.ready)
            if !isStopped { receiveHeader() }
        case .failed:
            finish("Secure pairing failed. Check the pairing key and local network.")
        case .cancelled:
            finish("Disconnected.")
        case .setup, .preparing, .waiting:
            break // The bounded handshake deadline also covers unresolved or waiting connections.
        @unknown default:
            finish("The connection entered an unsupported state.")
        }
    }

    private func receiveHeader() {
        guard isReady, !isStopped else { return }
        beginIdleDeadline()
        receiveComponent(length: FrameCodec.headerLength, isHeader: true) { [weak self] data, complete in
            guard let self, !self.isStopped else { return }
            do {
                let length = try FrameCodec.payloadLength(from: data)
                guard !complete else {
                    self.finish("Truncated frame.")
                    return
                }
                self.receivePayload(length: length)
            } catch FrameError.invalidLength {
                self.finish("Invalid message length.")
            } catch {
                self.finish("Truncated frame.")
            }
        }
    }

    private func receivePayload(length: Int) {
        guard !isStopped else { return }
        receiveComponent(length: length, isHeader: false) { [weak self] data, complete in
            guard let self, !self.isStopped else { return }
            self.frameDeadline?.cancel()
            self.frameDeadline = nil
            // Read as of this frame's arrival, not as of its decode: a body that reached this
            // side before it advertised the binary format is judged by the rule in force then.
            let allowsBinary = self.didAdvertiseBinary
            // Ordinary input/heartbeat messages are tiny: deliver inline without a scheduling
            // hop on the Mac. Only bulky payloads need the background parsing path.
            if length <= 4_096 {
                self.deliverDecoded(try? FrameCodec.decode(data, expectedLength: length, allowsBinary: allowsBinary), complete: complete)
                return
            }
            // Video parsing must not occupy the headset UI thread while it is handling gestures.
            // Read only one message at a time to preserve wire ordering.
            self.messageDecodeTask = Task { @MainActor [weak self] in
                let message = await Task.detached(priority: .userInitiated) {
                    try? FrameCodec.decode(data, expectedLength: length, allowsBinary: allowsBinary)
                }.value
                guard let self, !self.isStopped, !Task.isCancelled else { return }
                self.messageDecodeTask = nil
                self.deliverDecoded(message, complete: complete)
            }
        }
    }

    private func deliverDecoded(_ message: DeskMessage?, complete: Bool) {
        guard !isStopped else { return }
        guard let message else { finish("Invalid message."); return }
        observeAdvertisement(in: message)
        guard !isStopped else { return }
        onMessage?(message)
        guard !isStopped else { return }
        if complete { finish("The other device disconnected.") }
        else { receiveHeader() }
    }

    /// Attaches this transport's optional binary-body capability to an application's existing
    /// H.264 advertisement, so neither application has to know the wire format exists. An
    /// advertisement the caller built itself is left exactly as written.
    private func advertising(_ message: DeskMessage) -> DeskMessage {
        guard message.kind == "capabilities",
              message.videoCodec == DeskMessage.supportedVideoCodec,
              message.wireFormat == nil else { return message }
        var advertised = message
        advertised.wireFormat = DeskMessage.binaryWireFormat
        return advertised
    }

    /// Records a peer's binary-body advertisement and answers it at most once.
    ///
    /// The client advertises on connect, so the Mac's acknowledgement is the only capabilities
    /// message the Mac ever sends, and the client — having already sent its own — stays silent on
    /// receiving it. Each side is bounded at one capabilities message per connection, which is
    /// what keeps an acknowledgement from being acknowledged in turn. An unrecognized format is
    /// ignored rather than answered, so a future value cannot be mistaken for this one.
    private func observeAdvertisement(in message: DeskMessage) {
        guard message.kind == "capabilities",
              message.wireFormat == DeskMessage.binaryWireFormat else { return }
        isUsingBinaryWireFormat = true
        guard !hasSentCapabilities else { return }
        send(DeskMessage(kind: "capabilities", videoCodec: DeskMessage.supportedVideoCodec))
    }

    @MainActor
    private final class ReceiveBuffer {
        var data = Data()

        init(capacity: Int) { data.reserveCapacity(capacity) }
    }

    private func receiveComponent(length: Int, isHeader: Bool, buffer: ReceiveBuffer? = nil, completion: @escaping (Data, Bool) -> Void) {
        guard !isStopped else { return }
        // A shared buffer prevents repeated Data copy-on-write as network fragments arrive.
        let buffer = buffer ?? ReceiveBuffer(capacity: length)
        let remaining = length - buffer.data.count
        // Detect the first header byte promptly to start the existing stall deadline. After
        // the header, the deadline already runs: aggregate the payload instead of waking the
        // main queue once per small network fragment.
        connection.receive(minimumIncompleteLength: isHeader ? 1 : remaining, maximumLength: remaining) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isStopped else { return }
                if let data { buffer.data.append(data) }
                if !buffer.data.isEmpty, self.frameDeadline == nil { self.beginFrameDeadline() }
                guard error == nil else {
                    self.finish(self.frameDeadline != nil ? "Truncated frame." : "The secure connection was interrupted.")
                    return
                }
                if buffer.data.count == length {
                    completion(buffer.data, complete)
                } else if complete || data?.isEmpty != false {
                    self.finish(isHeader && buffer.data.isEmpty ? "The other device disconnected." : "Truncated frame.")
                } else {
                    self.receiveComponent(length: length, isHeader: isHeader, buffer: buffer, completion: completion)
                }
            }
        }
    }

    private func beginIdleDeadline() {
        guard let idleTimeout else { return }
        idleDeadline?.cancel()
        idleGeneration &+= 1
        let generation = idleGeneration
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.idleDeadline != nil, self.idleGeneration == generation else { return }
                self.finish("The other device stopped responding. Reconnect and try again.")
            }
        }
        idleDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: deadline)
    }

    private func beginFrameDeadline() {
        idleDeadline?.cancel()
        idleDeadline = nil
        frameGeneration &+= 1
        let generation = frameGeneration
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.frameDeadline != nil, self.frameGeneration == generation else { return }
                self.finish("Truncated frame.")
            }
        }
        frameDeadline = deadline
        // Once a peer begins a frame it must finish promptly, even if it leaves TLS open.
        DispatchQueue.main.asyncAfter(deadline: .now() + frameTimeout, execute: deadline)
    }

    private func publish(_ state: DeskLinkState) {
        stateObserver?(state)
        guard !isStopped else { return }
        onState?(state)
    }

    private func finish(_ reason: String) {
        guard !isStopped else { return }
        isStopped = true
        isReady = false
        deadline?.cancel()
        deadline = nil
        frameDeadline?.cancel()
        frameDeadline = nil
        idleDeadline?.cancel()
        idleDeadline = nil
        messageDecodeTask?.cancel()
        messageDecodeTask = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        pendingBytes = 0
        screenPendingBytes = 0
        screenPendingByDisplay.removeAll()
        let observer = stateObserver
        let callback = onState
        stateObserver = nil
        onState = nil
        onMessage = nil
        observer?(.disconnected(reason))
        callback?(.disconnected(reason))
    }
}
