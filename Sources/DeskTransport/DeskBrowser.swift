import Combine
import Foundation
import Network

/// The part of `NWBrowser` that `DeskBrowser` drives. Production wraps `NWBrowser` itself; tests
/// substitute a fake, so a failure and the restart after it run without touching the network.
@MainActor
protocol BonjourBrowsing: AnyObject {
    func start(onState: @escaping @Sendable (NWBrowser.State) -> Void,
               onResults: @escaping @Sendable (Set<NWBrowser.Result>) -> Void)
    func cancel()
}

/// `NWBrowser` for VisionDesk's Bonjour service, peer-to-peer links included.
@MainActor
private final class SystemBonjourBrowser: BonjourBrowsing {
    private let browser: NWBrowser

    init() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: SecureParameters.serviceType, domain: "local."), using: parameters)
    }

    func start(onState: @escaping @Sendable (NWBrowser.State) -> Void,
               onResults: @escaping @Sendable (Set<NWBrowser.Result>) -> Void) {
        browser.stateUpdateHandler = onState
        browser.browseResultsChangedHandler = { results, _ in onResults(results) }
        browser.start(queue: .main)
    }

    func cancel() {
        browser.stateUpdateHandler = nil
        browser.browseResultsChangedHandler = nil
        browser.cancel()
    }
}

@MainActor
public final class DeskBrowser: ObservableObject {
    @Published public private(set) var results: [NWBrowser.Result] = []
    /// One of the strings below. The headset app matches them exactly to choose its guidance.
    @Published public private(set) var status = "Discovery stopped."

    static let stoppedStatus = "Discovery stopped."
    static let searchingStatus = "Looking for Macs ready to pair."
    static let waitingStatus = "Waiting for access to the local network."
    static let restartingStatus = "Discovery was interrupted. Searching again shortly."
    static let failedStatus = "Could not discover Macs. Check Local Network access and try again."
    static let unsupportedStatus = "Discovery entered an unsupported state."

    /// Seconds to wait before each automatic restart after a failure. A failed `NWBrowser` never
    /// recovers by itself, and discovery used to stay dead until something started it again. The
    /// budget belongs to one `start()`: a browser that keeps failing settles on `failedStatus`
    /// after about half a minute instead of retrying forever.
    static let restartDelays: [UInt64] = [1, 2, 4, 8, 16]

    private var browser: (any BonjourBrowsing)?
    private var generation: UInt64 = 0
    private var restartTask: Task<Void, Never>?
    private var restartsUsed = 0
    private let makeBrowser: @MainActor () -> any BonjourBrowsing
    private let sleep: @Sendable (UInt64) async throws -> Void

    public convenience init() {
        self.init(makeBrowser: { SystemBonjourBrowser() },
                  sleep: { seconds in try await Task.sleep(nanoseconds: seconds * 1_000_000_000) })
    }

    /// Tests supply the browser and the wait, so a failure and its restart run without the network
    /// or real time.
    init(makeBrowser: @escaping @MainActor () -> any BonjourBrowsing,
         sleep: @escaping @Sendable (UInt64) async throws -> Void) {
        self.makeBrowser = makeBrowser
        self.sleep = sleep
    }

    /// Starts discovery with a fresh restart budget, replacing any browser or pending restart.
    public func start() {
        restartsUsed = 0
        begin()
    }

    /// Ends discovery, including a pending restart.
    public func stop() {
        end(with: Self.stoppedStatus)
    }

    private func begin() {
        reset()
        let generation = self.generation
        results = []
        guard generation == self.generation else { return }
        status = Self.searchingStatus
        guard generation == self.generation else { return }
        let browser = makeBrowser()
        self.browser = browser
        browser.start(onState: { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state, generation: generation) }
        }, onResults: { [weak self] found in
            MainActor.assumeIsolated { self?.show(found, generation: generation) }
        })
    }

    private func handle(_ state: NWBrowser.State, generation: UInt64) {
        guard self.generation == generation, browser != nil else { return }
        switch state {
        case .ready:
            status = Self.searchingStatus
        case .waiting:
            status = Self.waitingStatus
        case .failed:
            recover()
        case .setup, .cancelled:
            break
        @unknown default:
            end(with: Self.unsupportedStatus)
        }
    }

    private func show(_ found: Set<NWBrowser.Result>, generation: UInt64) {
        guard self.generation == generation, browser != nil else { return }
        results = found.filter {
            if case .service = $0.endpoint { return true }
            return false
        }.sorted { lhs, rhs in
            Self.sortKey(lhs.endpoint).localizedStandardCompare(Self.sortKey(rhs.endpoint)) == .orderedAscending
        }
    }

    /// Replaces a failed browser after a wait, at most `restartDelays.count` times per `start()`.
    /// The failed browser's results go with it. `start()` or `stop()` during the wait cancels it.
    private func recover() {
        guard restartsUsed < Self.restartDelays.count else {
            end(with: Self.failedStatus)
            return
        }
        let delay = Self.restartDelays[restartsUsed]
        restartsUsed += 1
        guard let generation = end(with: Self.restartingStatus) else { return }
        let sleep = self.sleep
        restartTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.restartTask = nil
            self.begin()
        }
    }

    /// Cancels the browser and any pending restart, clears the results and shows `message`.
    /// Returns the generation it settled on, or nil when a subscriber restarted or stopped
    /// discovery while this ran.
    @discardableResult
    private func end(with message: String) -> UInt64? {
        reset()
        let generation = self.generation
        results = []
        guard generation == self.generation else { return nil }
        status = message
        guard generation == self.generation else { return nil }
        return generation
    }

    private func reset() {
        generation &+= 1
        restartTask?.cancel()
        restartTask = nil
        browser?.cancel()
        browser = nil
    }

    private static func sortKey(_ endpoint: NWEndpoint) -> String {
        guard case let .service(name, type, domain, interface) = endpoint else { return "" }
        return "\(name)\u{1f}\(type)\u{1f}\(domain)\u{1f}\(interface?.index ?? 0)"
    }
}
