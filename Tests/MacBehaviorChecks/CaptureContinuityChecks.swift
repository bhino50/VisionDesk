import Foundation
import DeskCore

@MainActor
func runCaptureContinuityChecks(_ runner: CheckRunner) async {
    await runner.check("Static capture repeats without idle callbacks and suspension and stop revoke repeats") {
        let queue = DispatchQueue(label: "VisionDesk.check.repeat")
        let count = RepeatCounter()
        let repeater = CaptureIdleRepeater(queue: queue, interval: 0.01) { count.increment() }
        queue.sync { repeater.start() }
        try await Task.sleep(nanoseconds: 40_000_000)
        runner.expectEqual(count.value, 0, "nothing is repeated before a genuine source exists")
        queue.sync { repeater.sourceAvailable = true }
        await waitUntil(seconds: 1) { count.value >= 2 }
        runner.expect(count.value >= 2, "the independent clock repeats an unchanged source without any idle callbacks")
        queue.sync { repeater.sourceAvailable = false }
        let paused = count.value
        try await Task.sleep(nanoseconds: 40_000_000)
        runner.expectEqual(count.value, paused, "an observed source suspension prevents stale repeats")
        queue.sync { repeater.sourceAvailable = true }
        await waitUntil(seconds: 1) { count.value > paused }
        runner.expect(count.value > paused, "a genuine source return resumes its clock")
        queue.sync { repeater.stop(); repeater.sourceAvailable = true }
        let stopped = count.value
        try await Task.sleep(nanoseconds: 40_000_000)
        runner.expectEqual(count.value, stopped, "stop cancels the timer even if availability changes later")
    }
    await runner.check("Transport video drops gate only the broken display until an accepted keyframe") {
        var recovery = VideoSendRecovery()
        recovery.requireKeyframes(for: [1, 2])
        runner.expect(!recovery.allows(id: 1, isKeyframe: false), "negotiation starts on a decodable keyframe")
        recovery.record(id: 1, isKeyframe: true, sent: true)
        runner.expect(recovery.allows(id: 1, isKeyframe: false), "accepted keyframes reopen prediction")
        recovery.record(id: 1, isKeyframe: false, sent: false)
        runner.expect(!recovery.allows(id: 1, isKeyframe: false), "a refused transport frame closes the reference chain")
        recovery.record(id: 1, isKeyframe: true, sent: false)
        runner.expect(!recovery.allows(id: 1, isKeyframe: false), "a refused repair does not reopen the chain")
        recovery.record(id: 2, isKeyframe: true, sent: true)
        runner.expect(recovery.allows(id: 2, isKeyframe: false), "another screen stays independent")
        recovery.record(id: 1, isKeyframe: true, sent: true)
        runner.expect(recovery.allows(id: 1, isKeyframe: false), "successful repair restores prediction")
    }
}

private final class RepeatCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
