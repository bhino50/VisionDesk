import DeskCore
import DeskTransport
import Foundation

/// Delayed native retirement and preparation are driven explicitly; no screen is captured.
@MainActor
func runCaptureLifecycleChecks(_ runner: CheckRunner) async {
    await runner.check("Stopping four displays revokes every output before native retirement finishes") {
        let lifecycle = CaptureLifecycle()
        let gate = CaptureCheckGate()
        let captures = (0..<4).map { _ in CaptureCheckLifetime(gate: gate) }
        var starts = 0
        lifecycle.stop(captures, revoke: { $0.revoke() }, retire: { await $0.retire() })
        lifecycle.start { starts += 1 }
        runner.expect(captures.allSatisfy { $0.revoked }, "all four outputs are revoked synchronously")
        await settleUntil { captures.contains { $0.retirements > 0 } }
        runner.expectEqual(starts, 0, "new capture waits while one old native stop is suspended")
        gate.open()
        await settleUntil { starts == 1 }
        runner.expectEqual(captures.map(\.retirements), [1, 1, 1, 1], "every old capture finishes retirement")
        runner.expectEqual(starts, 1, "the replacement begins only after every old stop completes")
    }

    await runner.check("Rapid Start and Stop requests keep only the latest start behind pending teardown") {
        let lifecycle = CaptureLifecycle()
        let preparation = CaptureCheckGate()
        let retirement = CaptureCheckGate()
        let capture = CaptureCheckLifetime(gate: retirement)
        var preparing = false
        var starts: [Int] = []
        lifecycle.start { preparing = true; await preparation.wait() }
        await settleUntil { preparing }
        for request in 0..<100 {
            lifecycle.stop([capture], revoke: { $0.revoke() }, retire: { await $0.retire() })
            lifecycle.start { starts.append(request) }
        }
        runner.expect(starts.isEmpty, "a pending native start is not raced by later starts")
        preparation.open()
        await settleUntil { capture.retirements == 1 }
        runner.expect(starts.isEmpty, "native retirement remains a barrier after preparation returns")
        retirement.open()
        await settleUntil { !starts.isEmpty }
        runner.expectEqual(starts, [99], "99 obsolete starts are replaced, not queued")
        runner.expectEqual(capture.retirements, 1, "the same capture is not retired 100 times")
    }

    await runner.check("Stop withdraws a queued start without restarting when previous preparation returns") {
        let lifecycle = CaptureLifecycle()
        let gate = CaptureCheckGate()
        var preparing = false
        var starts = 0
        lifecycle.start { preparing = true; await gate.wait() }
        await settleUntil { preparing }
        lifecycle.start { starts += 1 }
        lifecycle.stop([CaptureCheckLifetime](), revoke: { $0.revoke() }, retire: { await $0.retire() })
        gate.open()
        for _ in 0..<20 { await Task.yield() }
        runner.expectEqual(starts, 0, "an explicit stop never leaves an automatic start queued")
    }

    await runner.check("An encoder failure during preparation remains latched for the whole pending session") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in },
                                   saveLANConfiguration: { _ in }, saveRemoteConfiguration: { _ in },
                                   contentProvider: { throw CheckError.preparationAbandoned },
                                   inventory: { [syntheticDisplay(1)] })
        model.busy = true
        let reason = "Test encoder unavailable; image updates remain available."
        model.degradeToImageUpdates(reason)
        runner.expectEqual(model.videoFallbackReason, reason, "preparation must not discard a one-shot encoder failure")
        runner.expectEqual(model.status, reason, "the owner sees why video fell back")
        runner.expect(!model.sendingH264, "the pending session remains on image updates")
        model.stop()
        model.start()
        runner.expect(model.videoFallbackReason == nil, "a deliberate new session gets a fresh encoder attempt")
        model.stop()
    }

    await runner.check("A late encoder failure after Stop cannot revive or change sharing") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in },
                                   saveLANConfiguration: { _ in }, saveRemoteConfiguration: { _ in },
                                   contentProvider: { throw CheckError.preparationAbandoned },
                                   inventory: { [syntheticDisplay(1)] })
        model.stop()
        let status = model.status
        model.degradeToImageUpdates("Late failure")
        runner.expect(model.videoFallbackReason == nil, "inactive sessions ignore encoder callbacks")
        runner.expectEqual(model.status, status, "a stopped session keeps the Stop result")
        runner.expect(!model.sharing && !model.busy, "no capture was restarted")
    }
}

@MainActor
private final class CaptureCheckGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

@MainActor
private final class CaptureCheckLifetime {
    private let gate: CaptureCheckGate
    private(set) var revoked = false
    private(set) var retirements = 0

    init(gate: CaptureCheckGate) { self.gate = gate }
    func revoke() { revoked = true }
    func retire() async { retirements += 1; await gate.wait() }
}

@MainActor
private func settleUntil(_ condition: () -> Bool) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
}
