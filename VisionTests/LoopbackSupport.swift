import DeskCore
import Foundation
import Network
import XCTest
@testable import DeskTransport
@testable import VisionDesk

/// Shared plumbing for the suites that drive the production `DeskClientModel` against the mock
/// Mac. Every session built here is reached the way the app reaches one: a real scene phase, a
/// real PSK-TLS handshake against the production `DeskServer`, real status grants and real
/// decoded JPEG frames. Keychain and preferences are the in-memory fakes, so a run leaves no
/// pairing key and no saved Mac behind.
@MainActor
enum Loopback {
    enum WaitError: Error { case timeout }

    typealias ConnectionFactory = @MainActor (NWEndpoint, PairingKey) -> DeskConnection

    /// Short enough to exercise in seconds, in the same shape as the standard policy: silence
    /// is reported well before a session is recycled, and at most twice in a row.
    static let fastPolicy = LinkMonitor.Policy(quietAfter: 0.6, recoverAfter: 1.5, maximumAutomaticRecoveries: 2)

    /// Reports silence quickly and, within any test's lifetime, never recycles on its own.
    static let reportOnlyPolicy = LinkMonitor.Policy(quietAfter: 0.6, recoverAfter: 3_600, maximumAutomaticRecoveries: 2)

    /// The smallest send queue `DeskConnection` accepts: its precondition requires more than
    /// the 64 KiB control reserve, so this is 65 KiB plus one byte.
    static let constrainedQueueBytes = 65_537

    /// Polls a main-actor condition. Loopback delivery and image decoding are asynchronous, so
    /// there is no single hop to await.
    static func waitUntil(timeout: TimeInterval = 6, file: StaticString = #filePath, line: UInt = #line,
                          _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1_000))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for a client or loopback event.", file: file, line: line)
                throw WaitError.timeout
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// A negative result has no event to await, so elapsed time is the only proof.
    static func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func store(_ keychain: MemoryKeychain) -> PairingKeyStore {
        PairingKeyStore(service: "org.visiondesk.VisionDesk.pairing.visiontests", keychain: keychain)
    }

    /// A real interface from the system's own path report, or nil if it reports none in time.
    /// `NWInterface` cannot be built directly, so the identity tests borrow one.
    static func anyInterface() async throws -> NWInterface? {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "VisionTests.path"))
        defer { monitor.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let interface = monitor.currentPath.availableInterfaces.first { return interface }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    /// A preferences suite of its own, for a test that needs the production preference store.
    /// The caller removes it with `removePersistentDomain(forName:)`, so a run leaves nothing.
    static func throwawayDefaults() throws -> (defaults: UserDefaults, name: String) {
        let name = "org.visiondesk.VisionDesk.visiontests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    static func address(for mac: MockMac) throws -> String {
        let endpoint = try XCTUnwrap(mac.endpoint)
        guard case let .hostPort(_, port) = endpoint else { throw WaitError.timeout }
        return "127.0.0.1:\(port.rawValue)"
    }

    /// A model with in-memory stores, built with the production channel unless a test supplies
    /// its own factory for the same authenticated `DeskConnection`. A test may pass the
    /// production preference store over a throwaway suite instead of the in-memory one.
    static func model(keychain: MemoryKeychain = MemoryKeychain(),
                      preferences: any RememberedMacStore = MemoryRememberedMacStore(),
                      linkPolicy: LinkMonitor.Policy = .standard,
                      makeConnection: ConnectionFactory? = nil) -> DeskClientModel {
        guard let makeConnection else {
            return DeskClientModel(keys: store(keychain), preferences: preferences, linkPolicy: linkPolicy)
        }
        return DeskClientModel(keys: store(keychain), preferences: preferences,
                               linkPolicy: linkPolicy, makeConnection: makeConnection)
    }

    /// A Mac found by discovery: the one-time session `connect(to:key:name:)` makes, which is
    /// never remembered and never dialled again.
    static func discoveredSession(linkPolicy: LinkMonitor.Policy = .standard,
                                  makeConnection: ConnectionFactory? = nil,
                                  mac: MockMac? = nil) async throws -> LoopbackSession {
        let session = try begin(linkPolicy: linkPolicy, makeConnection: makeConnection, mac: mac)
        do {
            try session.mac.start()
            try await waitUntil { session.mac.endpoint != nil }
            session.model.connect(to: try XCTUnwrap(session.mac.endpoint), key: session.mac.key, name: "Loopback Mac")
            try await waitUntil(timeout: 15) { session.model.isLinked && session.mac.isConnected }
            return session
        } catch {
            session.close()
            throw error
        }
    }

    /// A Mac reached by its typed address and code, whose listener outlives a session so a
    /// reconnection has somewhere to land. Pass `mac` to configure it before it starts.
    static func directSession(linkPolicy: LinkMonitor.Policy = .standard,
                              makeConnection: ConnectionFactory? = nil,
                              mac: MockMac? = nil) async throws -> LoopbackSession {
        let session = try begin(linkPolicy: linkPolicy, makeConnection: makeConnection, mac: mac)
        do {
            try session.mac.start(allowReconnect: true)
            try await waitUntil { session.mac.endpoint != nil }
            session.model.directAddress = try address(for: session.mac)
            session.model.pairingCode = session.mac.key.displayValue
            session.model.remembersThisMac = false
            session.model.connectDirectly()
            try await waitUntil(timeout: 15) { session.model.isLinked && session.mac.isConnected }
            return session
        } catch {
            session.close()
            throw error
        }
    }

    private static func begin(linkPolicy: LinkMonitor.Policy, makeConnection: ConnectionFactory?,
                              mac: MockMac?) throws -> LoopbackSession {
        let frame = try XCTUnwrap(DeskFixtures.jpeg(), "The platform could not encode a JPEG fixture.")
        let session = LoopbackSession(model: model(linkPolicy: linkPolicy, makeConnection: makeConnection),
                                      mac: mac ?? MockMac(), scene: UUID(), frame: frame)
        session.model.updateScene(session.scene, phase: .active)
        return session
    }

    /// The production channel, recorded as it is built. With `maximumPendingBytes` it is built
    /// with that send queue instead of the default; authentication is the same PSK-TLS either way.
    static func recordingFactory(_ log: ChannelLog, maximumPendingBytes: Int? = nil) -> ConnectionFactory {
        { endpoint, key in
            let channel: DeskConnection
            if let maximumPendingBytes {
                channel = DeskConnection(
                    connection: NWConnection(to: endpoint, using: SecureParameters.make(key: key)),
                    idleTimeout: nil, maximumPendingBytes: maximumPendingBytes
                )
            } else {
                channel = DeskConnection(endpoint: endpoint, key: key)
            }
            log.channels.append(channel)
            return channel
        }
    }

    /// Fills a live constrained channel's send queue with real control messages until exactly
    /// `free` bytes remain, never offering one that would be refused — a refusal here would end
    /// the session in the filler instead of at the send under test.
    ///
    /// Sizes come from the encoder and callers check the channel's own counter, so a framing
    /// change fails loudly rather than passing for the wrong reason. The last message is sized
    /// to land the gap exactly: one ASCII character of `text` is one byte of JSON.
    static func fillSendQueue(_ channel: DeskConnection, leaving free: Int) throws {
        func text(_ length: Int) -> DeskMessage {
            DeskMessage(kind: "input", displayID: 1, action: "text",
                        text: String(repeating: "a", count: length))
        }
        let target = constrainedQueueBytes - free
        let smallest = try FrameCodec.encode(text(1)).count
        let bulk = text(2_048)
        let bulkBytes = try FrameCodec.encode(bulk).count
        while target - channel.pendingBytes >= bulkBytes + smallest {
            XCTAssertTrue(channel.send(bulk), "a control message that fits may not be refused")
        }
        let gap = target - channel.pendingBytes
        XCTAssertGreaterThanOrEqual(gap, smallest, "the remaining gap has to fit one message")
        XCTAssertTrue(channel.send(text(gap - smallest + 1)))
    }
}

/// The channels a factory built, in the order the model asked for them.
@MainActor
final class ChannelLog {
    var channels: [DeskConnection] = []
}

/// A live loopback session and what is needed to drive and close it.
@MainActor
struct LoopbackSession {
    let model: DeskClientModel
    let mac: MockMac
    let scene: UUID
    let frame: Data

    /// Removes the only scene, which is the production path that disconnects and stops
    /// discovery, then closes the mock Mac's listener.
    func close() {
        model.updateScene(scene, phase: nil)
        mac.stop()
    }

    /// What a Mac sends once its wearer enables control: the display list, the grant, and a
    /// decoded frame for every display, after which each display accepts input.
    func grantControl(displays: [DisplayInfo] = [DeskFixtures.display]) async throws {
        XCTAssertTrue(mac.publish(displays: displays))
        try await Loopback.waitUntil { model.displays.count == displays.count }
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { model.isMacControlEnabled }
        for display in displays { XCTAssertTrue(mac.sendFrame(frame, displayID: display.id)) }
        try await Loopback.waitUntil { displays.allSatisfy { model.canControl(displayID: $0.id) } }
    }
}
