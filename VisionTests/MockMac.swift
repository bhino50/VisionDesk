import DeskCore
import Foundation
import Network
import Security
import UIKit
@testable import DeskTransport
@testable import VisionDesk

/// A stand-in Mac companion built on the production `DeskServer`. It authenticates with a
/// real ephemeral pairing key over a TLS loopback listener, records every protocol message
/// the client sends, and publishes genuine display metadata, JPEG frames and status grants.
///
/// Nothing here fakes client state: the client reaches `isLinked` only by completing the real
/// handshake, and `isMacControlEnabled` only by receiving an actual status grant over the wire.
@MainActor
final class MockMac {
    /// The pairing key this Mac authenticates with. Passing an existing key models
    /// a Mac that a client already remembers across an app relaunch.
    let key: PairingKey

    init(key: PairingKey = .generate()) {
        self.key = key
    }

    /// Every message received from the client, in arrival order.
    private(set) var received: [DeskMessage] = []
    /// The same messages, each with the session it arrived in: 1 for the first client that
    /// completed the handshake, 2 for the next on the same listener, and so on.
    private(set) var log: [(session: Int, message: DeskMessage)] = []
    private(set) var isConnected = false
    private(set) var buttonHeld = false
    private(set) var releaseCount = 0

    /// Opt-in model of the companion's consent rules for a Mac that allows control and
    /// reconnection (`CompanionModel.attach`, `receive`, `revoke`): every attach answers "not
    /// enabled" and re-arms the grant unless a Stop from the headset paused it, the first
    /// heartbeat of a re-armed session enables control, a Stop pauses and answers "not enabled",
    /// and a Resume request grants. Off by default, so every other test drives grants by hand.
    var emulatesConsent = false
    /// Models a Mac whose pairing outlives its sessions, as a persistent LAN listener's does: every
    /// status it sends carries `keepsPairing: true`, and each session opens with the attach status
    /// that carries it. Off by default, which is every Mac that pairs for one session.
    var keepsPairing = false
    static let attachStatus = "Connected securely. Enable input on this Mac if needed."
    private(set) var controlEnabled = false
    private(set) var pausedByHeadset = false
    private var grantArmed = false
    /// The session whose messages are discarded unread. See `stopHearingCurrentSession`.
    private var unheardSession: Int?

    private let server = DeskServer()
    private var host: DeskConnection?

    /// Received messages without the client's periodic heartbeat, which is unrelated noise
    /// for ordering assertions.
    var controlMessages: [DeskMessage] { received.filter { $0.kind != "heartbeat" } }

    /// Pointer, scroll and keyboard actions in arrival order.
    var actions: [String] { received.compactMap { $0.kind == "input" ? $0.action : nil } }

    var endpoint: NWEndpoint? {
        guard let raw = server.port, let port = NWEndpoint.Port(rawValue: raw) else { return nil }
        return .hostPort(host: "127.0.0.1", port: port)
    }

    /// How many clients have completed the real handshake so far. A reconnection
    /// is only proven by this going up a second time on the same listener.
    private(set) var sessionCount = 0

    /// Starts the loopback listener. The port appears asynchronously; poll `endpoint`.
    ///
    /// With `allowReconnect` the listener outlives a session, which is what a Mac
    /// configured for unattended reconnection does. The default keeps the
    /// one-session behavior every existing test relies on. Pass `port` to rebind a
    /// known port, which a client holding a saved address has to be able to reach
    /// again; that path stays on loopback and off Bonjour, as `startLoopback` does.
    func start(allowReconnect: Bool = false, port: UInt16? = nil) throws {
        server.onConnection = { [weak self] connection in
            guard let self else { return }
            self.host = connection
            self.isConnected = true
            self.sessionCount += 1
            let session = self.sessionCount
            // The server keeps its own `stateObserver`, so these application callbacks do
            // not disturb its session bookkeeping.
            connection.onMessage = { [weak self] message in
                guard let self, self.unheardSession != session else { return }
                self.received.append(message)
                self.log.append((session, message))
                if message.kind == "input", message.action == "leftDown" { self.buttonHeld = true }
                if message.kind == "stop" || (message.kind == "input" && message.action == "leftUp") {
                    self.releaseButton()
                }
                if self.emulatesConsent { self.applyConsent(message) }
            }
            connection.onState = { [weak self] state in
                guard case .disconnected = state else { return }
                self?.isConnected = false
                self?.controlEnabled = false
                self?.releaseButton()
            }
            if self.emulatesConsent {
                self.attachConsent()
            } else if self.keepsPairing {
                self.publishStatus(Self.attachStatus, controlEnabled: false)
            }
        }
        if let port {
            try server.start(key: key, name: "VisionDesk Mock", port: port,
                             allowReconnect: allowReconnect, bindHost: "127.0.0.1")
        } else {
            try server.startLoopback(key: key, allowReconnect: allowReconnect)
        }
    }

    func stop() {
        host?.cancel()
        host = nil
        server.stop()
        isConnected = false
        controlEnabled = false
        releaseButton()
    }

    /// Drops the live session while leaving the listener exactly as it was. This is
    /// the unexpected-drop case — a sleeping Mac, a VPN hiccup — as distinct from
    /// `stop()`, which takes the whole Mac away.
    func dropConnection() {
        host?.cancel()
        host = nil
        isConnected = false
        controlEnabled = false
        releaseButton()
    }

    /// What one session received, in arrival order, heartbeats included.
    func received(inSession session: Int) -> [DeskMessage] {
        log.filter { $0.session == session }.map(\.message)
    }

    /// The path from the headset to this Mac fails while the connection stays open, as on a
    /// dead VPN path that TCP has not noticed: everything the client sends in the current
    /// session from now on is discarded unread. This Mac sends nothing by itself, so the
    /// headset hears silence too. The next session is heard again.
    func stopHearingCurrentSession() {
        unheardSession = sessionCount
    }

    private func releaseButton() {
        guard buttonHeld else { return }
        buttonHeld = false
        releaseCount += 1
    }

    // MARK: Consent, when emulated

    private func attachConsent() {
        controlEnabled = false
        grantArmed = !pausedByHeadset
        publishStatus(Self.attachStatus, controlEnabled: false)
    }

    private func applyConsent(_ message: DeskMessage) {
        switch message.kind {
        case "heartbeat":
            guard grantArmed, !controlEnabled else { return }
            grantArmed = false
            grant()
        case "stop":
            grantArmed = false
            pausedByHeadset = true
            controlEnabled = false
            publishStatus("Input stopped from Vision Pro.", controlEnabled: false)
        case "requestControl":
            grant()
        default:
            break
        }
    }

    private func grant() {
        pausedByHeadset = false
        controlEnabled = true
        publishStatus("Mac control enabled for all shared displays.", controlEnabled: true)
    }

    @discardableResult
    func send(_ message: DeskMessage) -> Bool {
        host?.send(message) ?? false
    }

    /// Mirrors the companion's `publishStatus`, which always carries the current grant, and on a
    /// Mac that keeps its pairing also says so.
    @discardableResult
    func publishStatus(_ status: String, controlEnabled: Bool) -> Bool {
        send(DeskMessage(kind: "status", status: status, controlEnabled: controlEnabled,
                         keepsPairing: keepsPairing ? true : nil))
    }

    @discardableResult
    func publish(displays: [DisplayInfo]) -> Bool {
        send(DeskMessage(kind: "displays", displays: displays))
    }

    @discardableResult
    func sendFrame(_ jpeg: Data, displayID: UInt32 = 1) -> Bool {
        send(DeskMessage(kind: "frame", displayID: displayID, jpeg: jpeg))
    }

    /// The other screen source. A real Mac sends a cached JPEG for every display the moment a
    /// client attaches and only moves to H.264 once it knows the client's codec, so a session
    /// that uses both is the ordinary case rather than a contrived one.
    @discardableResult
    func sendVideo(_ frame: EncodedVideoFrame, displayID: UInt32 = 1) -> Bool {
        send(DeskMessage(kind: "video", displayID: displayID, video: frame))
    }
}

enum DeskFixtures {
    static let display = DisplayInfo(
        id: 1, name: "Loopback Display", width: 1_920, height: 1_080,
        originX: 0, originY: 0, pointWidth: 1_920, pointHeight: 1_080
    )

    /// A different pixel grid for the same display, as a resolution change would report.
    static let resizedDisplay = DisplayInfo(
        id: 1, name: "Loopback Display", width: 1_280, height: 800,
        originX: 0, originY: 0, pointWidth: 1_280, pointHeight: 800
    )

    /// The same pixel grid with a different point size, as a scaling change would report.
    static let rescaledDisplay = DisplayInfo(
        id: 1, name: "Loopback Display", width: 1_920, height: 1_080,
        originX: 0, originY: 0, pointWidth: 960, pointHeight: 540
    )

    /// An actual JPEG at an exact pixel size, encoded by the platform rather than captured.
    /// Small on purpose: the decoder path is what matters, not the payload size.
    @MainActor
    static func jpeg(width: Int = 32, height: Int = 20) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2))
        }
        return image.jpegData(compressionQuality: 0.6)
    }

    /// An access unit that passes every wire rule in `EncodedVideoFrame.isValid` — AVCC
    /// framing, an IDR slice, both parameter sets of the right NAL type — while carrying
    /// filler rather than a real encoded picture.
    ///
    /// That combination is exactly what a source-transition test needs: the frame is admitted
    /// by the sequencer, so it reaches the video pipeline and the pipeline commits to it, and
    /// then VideoToolbox cannot build a session from the synthetic parameter sets, so the
    /// video pipeline's own answer is "no picture". Whatever the stream shows afterwards is
    /// therefore attributable to the transition, not to a decode nobody controls.
    static func syntheticVideoKeyframe(sequence: UInt64 = 0, width: Int = 64, height: Int = 64) -> EncodedVideoFrame {
        func nalUnit(type: UInt8, byteCount: Int) -> Data {
            Data([type & 0x1F]) + Data(repeating: 0xA5, count: byteCount - 1)
        }
        let slice = nalUnit(type: 5, byteCount: 24)
        let length = UInt32(slice.count)
        var payload = Data([
            UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)
        ])
        payload.append(slice)
        return EncodedVideoFrame(
            width: width, height: height, sequence: sequence, isKeyframe: true,
            payload: payload,
            sps: nalUnit(type: 7, byteCount: 12), pps: nalUnit(type: 8, byteCount: 5)
        )
    }

    /// JPEG start-of-image bytes with no frame header, so no decoder can produce an image.
    /// The transport accepts it as a well-formed `frame` message, which is the point: the
    /// client's own decode path has to reject it.
    static let malformedJPEG: Data = {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        data.append(Data(repeating: 0x5A, count: 96))
        return data
    }()
}

/// In-memory Keychain for the remembered-Mac tests.
///
/// Nothing in this suite may touch the simulator's or device's real keychain: a
/// test run must not leave a pairing key behind, and must not depend on one that
/// a previous run left. Every store under test is built with this instead, which
/// also makes a locked or unentitled keychain testable by forcing a status.
/// `@unchecked Sendable` is accurate here — instances are used on one test thread.
final class MemoryKeychain: PairingKeychain, @unchecked Sendable {
    struct Entry: Hashable {
        let service: String
        let account: String
    }

    private(set) var items: [Entry: Data] = [:]
    private(set) var writeCount = 0
    private(set) var deleteCount = 0
    /// When set, every primitive reports this status instead of succeeding.
    var forcedStatus: OSStatus?

    func addItem(_ attributes: [String: Any]) -> OSStatus {
        if let forcedStatus { return forcedStatus }
        guard let entry = Self.entry(attributes),
              let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        guard items[entry] == nil else { return errSecDuplicateItem }
        items[entry] = data
        writeCount += 1
        return errSecSuccess
    }

    func copyItemData(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        if let forcedStatus { return (forcedStatus, nil) }
        guard let entry = Self.entry(query) else { return (errSecParam, nil) }
        guard let data = items[entry] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func updateItem(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        if let forcedStatus { return forcedStatus }
        guard let entry = Self.entry(query) else { return errSecParam }
        guard items[entry] != nil else { return errSecItemNotFound }
        guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        items[entry] = data
        writeCount += 1
        return errSecSuccess
    }

    func deleteItem(_ query: [String: Any]) -> OSStatus {
        if let forcedStatus { return forcedStatus }
        deleteCount += 1
        guard let entry = Self.entry(query) else { return errSecParam }
        guard items.removeValue(forKey: entry) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }

    private static func entry(_ attributes: [String: Any]) -> Entry? {
        guard let service = attributes[kSecAttrService as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String else { return nil }
        return Entry(service: service, account: account)
    }
}

/// In-memory stand-in for the app's preferences, so no plist is written either. Pending-Stop
/// routes are held as the bytes the production store would write, through the same codec.
final class MemoryRememberedMacStore: RememberedMacStore {
    private(set) var stored: RememberedMac?
    private(set) var clearCount = 0
    private(set) var stoppedRoutesData: Data?

    init(stored: RememberedMac? = nil) {
        self.stored = stored
    }

    func load() -> RememberedMac? { stored }

    func save(_ mac: RememberedMac) { stored = mac }

    func clear() {
        stored = nil
        clearCount += 1
    }

    func loadStoppedRoutes() -> Set<MacRoute> {
        PendingStopsCodec.decode(stoppedRoutesData)
    }

    func saveStoppedRoutes(_ routes: Set<MacRoute>) {
        stoppedRoutesData = routes.isEmpty ? nil : PendingStopsCodec.encode(routes)
    }
}
