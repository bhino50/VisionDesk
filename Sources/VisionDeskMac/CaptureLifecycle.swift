import Foundation

/// Serializes native capture preparation and retirement without queueing every Start/Stop
/// click. There is one runner, one replaceable pending start, and one stop per capture.
/// The model's generation check still decides whether a preparation may publish its result.
@MainActor
final class CaptureLifecycle {
    private var runner: Task<Void, Never>?
    private var pendingStart: (@MainActor () async -> Void)?
    private var pendingStops: [ObjectIdentifier: @MainActor () async -> Void] = [:]

    func start(_ operation: @escaping @MainActor () async -> Void) {
        pendingStart = operation
        runIfNeeded()
    }

    /// Revocation is synchronous for every display. Native teardown may suspend, but must
    /// complete before a later start can consume another set of capture/encoder resources.
    func stop<Capture: AnyObject>(_ captures: [Capture],
                                  revoke: (Capture) -> Void,
                                  retire: @escaping @MainActor (Capture) async -> Void) {
        pendingStart = nil
        for capture in captures {
            revoke(capture)
            pendingStops[ObjectIdentifier(capture)] = { await retire(capture) }
        }
        runIfNeeded()
    }

    private func runIfNeeded() {
        guard runner == nil else { return }
        runner = Task { @MainActor [self] in
            while true {
                if !pendingStops.isEmpty {
                    let stops = Array(pendingStops.values)
                    pendingStops.removeAll()
                    for stop in stops { await stop() }
                    continue
                }
                guard let operation = pendingStart else {
                    runner = nil
                    return
                }
                pendingStart = nil
                await operation()
            }
        }
    }
}
