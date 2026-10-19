import Foundation

/// Frame-mailbox behavior of the production `LatestFrameDelivery`. No capture is started.
///
/// Idle-repeat cadence is deliberately not checked here: reading
/// `DisplayCapture.idleRepeatInterval` back only mirrors the configured constant and proves
/// nothing about how often ScreenCaptureKit actually calls back. It stays a hardware test.
@MainActor
func runFrameDeliveryChecks(_ runner: CheckRunner) async {
    await runner.check("A burst collapses to one delivery carrying the newest frame") {
        let log = FrameLog()
        let delivery = LatestFrameDelivery { id, jpeg in log.append(id: id, jpeg: jpeg) }
        let burst = 500

        // The main actor cannot run the scheduled delivery until this check suspends, which
        // is exactly the backlog case a loaded companion has to survive.
        for index in 0..<burst { delivery.submit(id: 7, jpeg: payload(index)) }
        runner.expect(log.count == 0, "nothing may be delivered while the main actor is busy")

        await drainMainActor()
        let expectedID: UInt32? = 7
        let newest: Data? = payload(burst - 1)
        runner.expectEqual(log.count, 1, "deliveries for a \(burst)-frame burst")
        runner.expectEqual(log.entries.first?.id, expectedID, "delivered display identifier")
        runner.expectEqual(log.entries.first?.jpeg, newest, "only the newest frame survives")
    }

    await runner.check("Delivery keeps accepting frames after each drain") {
        let log = FrameLog()
        let delivery = LatestFrameDelivery { id, jpeg in log.append(id: id, jpeg: jpeg) }
        let rounds = 4
        for round in 0..<rounds {
            delivery.submit(id: 3, jpeg: payload(round))
            delivery.submit(id: 3, jpeg: payload(round + 100))
            await drainMainActor(rounds: 3)
        }
        let lastRoundNewest: Data? = payload(rounds - 1 + 100)
        runner.expectEqual(log.count, rounds, "one delivery per drained round, never a latched mailbox")
        runner.expectEqual(log.entries.last?.jpeg, lastRoundNewest, "the last round delivers its newest frame")
    }

    await runner.check("Capture-queue submissions stay bounded and end on the newest frame") {
        let log = FrameLog()
        let delivery = LatestFrameDelivery { id, jpeg in log.append(id: id, jpeg: jpeg) }
        let total = 240
        let queue = DispatchQueue(label: "VisionDesk.checks.capture", qos: .userInteractive)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                for index in 0..<total { delivery.submit(id: 9, jpeg: payload(index)) }
                continuation.resume()
            }
        }
        await drainMainActor()

        let newest: Data? = payload(total - 1)
        runner.expect(log.count >= 1, "a capture-queue burst must deliver at least once")
        runner.expect(log.count <= total, "deliveries must never exceed submissions, got \(log.count)")
        runner.expect(log.entries.allSatisfy { $0.id == 9 }, "every delivery must keep its display identifier")
        runner.expectEqual(log.entries.last?.jpeg, newest, "the newest frame must always arrive")
    }
}

private func payload(_ index: Int) -> Data {
    Data([UInt8(index % 251), UInt8(index / 251), 0xD8])
}
