import Foundation
import CoreGraphics
import DeskCore

@MainActor
func runKeyboardDeliveryChecks(_ runner: CheckRunner) async {
    await runner.check("An 8192-character paste crosses the real Mac limiter without truncation or duplicate text") {
        var events: [CGEvent] = []
        var now: TimeInterval = 100
        var busyReplies = 0
        var actions: [String] = []
        let output = InputOutput(permission: InputPermissionCache(isTrusted: { true }, canPostEvents: { true }),
                                 eventSink: { events.append($0) },
                                 displayBounds: { _ in CGRect(x: 0, y: 0, width: 1000, height: 1000) }, uptime: { now })
        let queue = KeyboardDelivery()
        queue.enable(); queue.canControl = { _ in true }
        var failures: [String] = []
        queue.onFailure = { failures.append($0) }
        queue.send = { message in
            runner.expect(message.isValid, "every queued request satisfies production protocol limits")
            runner.expect((message.text?.utf8.count ?? 0) <= 512, "bounded packet")
            let before = events.count
            let result = output.apply(message)
            if result == .busy {
                busyReplies += 1
                runner.expectEqual(events.count, before, "busy means zero posted events")
                now += 0.2
            } else { actions.append(message.action ?? "") }
            queue.receive(DeskMessage(kind: "keyboardResult", keyboardRequestID: message.keyboardRequestID,
                                      keyboardResult: result.rawValue))
            return true
        }
        let paste = String(repeating: "a", count: 8192)
        runner.expect(queue.enqueueText(paste + "\n世界 👩🏽‍💻", displayID: 1), "entire multiline paste admitted")
        runner.expect(queue.enqueueKey("tab", displayID: 1), "shortcut queues behind paste")
        let deadline = ContinuousClock.now + .seconds(5)
        while queue.pendingCount > 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        runner.expectEqual(queue.pendingCount, 0, "queue drained")
        runner.expect(busyReplies > 0, "real event budget applied backpressure")
        runner.expect(failures.isEmpty, "no silent or explicit delivery failure")
        runner.expectEqual(actions.suffix(3).map { $0 }, ["key", "text", "key"], "Return, final Unicode, Tab stay ordered")
        var units: [UInt16] = []
        for event in events where event.type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 0 {
            var count = 0; var buffer = [UInt16](repeating: 0, count: 64)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &count, unicodeString: &buffer)
            units += buffer.prefix(count)
        }
        runner.expectEqual(String(decoding: units, as: UTF16.self), paste + "世界 👩🏽‍💻", "every posted text character appears exactly once")
    }

    await runner.check("Keyboard queue rejects legacy hosts and over-capacity edits atomically") {
        let queue = KeyboardDelivery(); queue.canControl = { _ in true }
        var sent: [DeskMessage] = []; var failures: [String] = []
        queue.send = { sent.append($0); return true }; queue.onFailure = { failures.append($0) }
        runner.expect(!queue.enqueueText("hello", displayID: 1), "legacy companion cannot silently lose keyboard text")
        queue.enable()
        runner.expect(!queue.enqueueText(String(repeating: "a", count: KeyboardDelivery.maximumBytes + 1), displayID: 1), "byte cap refuses whole edit")
        runner.expect(!queue.enqueueText(String(repeating: "\n", count: KeyboardDelivery.maximumOperations + 1), displayID: 1), "operation cap refuses whole edit")
        runner.expect(sent.isEmpty && failures.count == 3, "zero packets from rejected edits with explicit feedback")
        runner.expect(queue.enqueueText("first", displayID: 1), "ordinary edit starts")
        runner.expect(queue.enqueueKey("return", displayID: 1), "key held behind unacknowledged text")
        runner.expectEqual(sent.count, 1, "one in-flight request")
        queue.cancel(endSession: true)
        runner.expectEqual(queue.pendingCount, 0, "session cancellation drops all pending work")
        runner.expect(!queue.isSupported, "new session must negotiate again")
    }

    await runner.check("Unknown keyboard acceptance never retries and late acknowledgements cannot revive a canceled queue") {
        let queue = KeyboardDelivery(); queue.enable(); queue.canControl = { _ in true }
        var sent: [DeskMessage] = []; var failures: [String] = []
        queue.send = { sent.append($0); return true }; queue.onFailure = { failures.append($0) }
        _ = queue.enqueueText("first", displayID: 1)
        _ = queue.enqueueText("second", displayID: 1)
        let deadline = ContinuousClock.now + .seconds(5)
        while queue.pendingCount > 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        runner.expectEqual(sent.count, 1, "timeout never resends text")
        runner.expectEqual(queue.pendingCount, 0, "timeout clears trailing work")
        runner.expect(failures.last?.contains("uncertain") == true, "uncertainty shown explicitly")
        queue.receive(DeskMessage(kind: "keyboardResult", keyboardRequestID: sent[0].keyboardRequestID, keyboardResult: "posted"))
        runner.expectEqual(sent.count, 1, "late reply cannot release second packet")
    }

    await runner.check("Duplicate busy acknowledgements schedule only one retry") {
        let queue = KeyboardDelivery(); queue.enable(); queue.canControl = { _ in true }
        var sent: [DeskMessage] = []
        queue.send = { sent.append($0); return true }
        _ = queue.enqueueText("once", displayID: 1)
        let busy = DeskMessage(kind: "keyboardResult", keyboardRequestID: sent[0].keyboardRequestID, keyboardResult: "busy")
        queue.receive(busy); queue.receive(busy)
        try await Task.sleep(for: .milliseconds(150))
        runner.expectEqual(sent.count, 2, "duplicate busy receipt creates one retry, not two")
        queue.receive(DeskMessage(kind: "keyboardResult", keyboardRequestID: sent[0].keyboardRequestID, keyboardResult: "posted"))
        try await Task.sleep(for: .milliseconds(120))
        runner.expectEqual(sent.count, 2, "posted receipt retires pending retry")
        queue.cancel()
    }

    await runner.check("Keyboard refusal and destination changes discard queued text without retry") {
        let queue = KeyboardDelivery(); queue.enable(); queue.canControl = { _ in true }
        var sent: [DeskMessage] = []
        queue.send = { sent.append($0); return true }
        _ = queue.enqueueText("old", displayID: 1)
        _ = queue.enqueueKey("return", displayID: 1)
        queue.receive(DeskMessage(kind: "keyboardResult", keyboardRequestID: sent[0].keyboardRequestID, keyboardResult: "rejected"))
        runner.expectEqual(queue.pendingCount, 0, "explicit rejection clears trailing Return")
        _ = queue.enqueueText("old", displayID: 1)
        _ = queue.enqueueText("new", displayID: 2)
        let count = sent.count
        queue.receive(DeskMessage(kind: "keyboardResult", keyboardRequestID: sent[1].keyboardRequestID, keyboardResult: "posted"))
        runner.expectEqual(sent.count, count, "old destination acknowledgement ignored")
        queue.canControl = { _ in false }
        queue.validateAvailability()
        runner.expectEqual(queue.pendingCount, 0, "heartbeat validation stops input after the live control gate closes")
        runner.expectEqual(sent.count, count, "control loss posts no additional packets")
        queue.cancel()
    }
}
