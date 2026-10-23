import CoreGraphics
import DeskCore
import Foundation
import XCTest
@testable import VisionDesk

/// Repeatable workloads through the same geometry, gesture and pacing code used by a screen.
/// These exercise event ordering and safety; they do not measure physical headset latency.
@MainActor
final class PointerStressTests: XCTestCase {
    private struct Screen {
        let id: UInt32
        let image: CGSize
        let container: CGSize

        func location(_ point: CGPoint) throws -> CGPoint {
            let rect = try XCTUnwrap(DisplayGeometry.imageRect(in: container, image: image))
            return CGPoint(x: rect.minX + point.x * rect.width,
                           y: rect.minY + point.y * rect.height)
        }

        func gesture(_ point: CGPoint, mode: ScreenInteractionMode) throws -> CGPoint {
            try XCTUnwrap(ScreenGesturePolicy.gesturePoint(location(point), in: container,
                                                           image: image, mode: mode))
        }
    }

    private let screens = [
        Screen(id: 1, image: CGSize(width: 1080, height: 1920),
               container: CGSize(width: 720, height: 900)),
        Screen(id: 2, image: CGSize(width: 900, height: 2560),
               container: CGSize(width: 480, height: 1000)),
        Screen(id: 3, image: CGSize(width: 2560, height: 1440),
               container: CGSize(width: 1000, height: 720)),
        Screen(id: 4, image: CGSize(width: 1920, height: 1920),
               container: CGSize(width: 800, height: 600))
    ]

    private struct Seeded {
        var state: UInt64

        mutating func unit() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 11) / CGFloat(UInt64(1) << 53)
        }

        mutating func point() -> CGPoint {
            CGPoint(x: 0.05 + 0.9 * unit(), y: 0.05 + 0.9 * unit())
        }
    }

    @MainActor
    private final class Harness {
        let input = PointerInput()
        var allowed: Set<UInt32> = [1, 2, 3, 4]
        var messages: [DeskMessage] = []

        init() {
            input.canControl = { [weak self] in self?.allowed.contains($0) == true }
            input.isLinked = { true }
            input.send = { [weak self] message in
                self?.messages.append(message)
                return true
            }
        }
    }

    func testSeededDragsKeepOwnershipAndBalancedButtonsAcrossFourScreens() async throws {
        let harness = Harness()
        var random = Seeded(state: 0x0D1AEC7)
        var samples = 0

        for screen in screens {
            for cycle in 0..<96 {
                let mode: ScreenInteractionMode = cycle.isMultiple(of: 2) ? .direct : .interact
                let token = UUID()
                let start = try screen.gesture(random.point(), mode: mode)
                let begin = harness.messages.count
                harness.input.updateGesture(token: token, displayID: screen.id, mode: mode,
                                            start: start, point: start, translation: .zero)
                var finalPoint = start
                for sample in 0..<48 {
                    finalPoint = try screen.gesture(random.point(), mode: mode)
                    harness.input.updateGesture(token: token, displayID: screen.id, mode: mode,
                                                start: start, point: finalPoint, translation: .zero)
                    samples += 1
                    if sample.isMultiple(of: 12) {
                        let count = harness.messages.count
                        let rival = screen.id % 4 + 1
                        harness.input.directTapClick(displayID: rival, at: finalPoint)
                        harness.input.updateGesture(token: UUID(), displayID: rival, mode: .direct,
                                                    start: finalPoint, point: finalPoint, translation: .zero)
                        harness.input.click(displayID: rival, action: "rightClick")
                        XCTAssertEqual(harness.messages.count, count, "Another screen cannot steal a held drag")
                    }
                }

                switch cycle % 4 {
                case 0:
                    harness.input.finishGesture(token: token, displayID: screen.id, mode: mode,
                                                start: start, point: finalPoint, translation: .zero)
                    let release = try XCTUnwrap(harness.messages.last)
                    XCTAssertEqual(try XCTUnwrap(release.x), Double(finalPoint.x), accuracy: 1e-9)
                    XCTAssertEqual(try XCTUnwrap(release.y), Double(finalPoint.y), accuracy: 1e-9)
                case 1:
                    harness.input.cancelGesture(token: token)
                case 2:
                    harness.allowed.remove(screen.id)
                    harness.input.updateGesture(token: token, displayID: screen.id, mode: mode,
                                                start: start, point: finalPoint, translation: .zero)
                    harness.allowed.insert(screen.id)
                default:
                    // A mode switch releases the current recognizer before the next mode owns it.
                    harness.input.releaseGesture()
                }

                XCTAssertNil(harness.input.activeDisplayID)
                let trace = Array(harness.messages[begin...])
                XCTAssertTrue(trace.allSatisfy { $0.displayID == screen.id })
                XCTAssertEqual(trace.filter { $0.action == "leftDown" }.count, 1)
                XCTAssertEqual(trace.filter { $0.action == "leftUp" }.count, 1)
                assertBalanced(trace)

                let end = harness.messages.count
                harness.input.updateGesture(token: token, displayID: screen.id, mode: mode,
                                            start: start, point: finalPoint, translation: .zero)
                harness.input.finishGesture(token: token, displayID: screen.id, mode: mode,
                                            start: start, point: finalPoint, translation: .zero)
                harness.input.gestureStateDidReset(token: token)
                XCTAssertEqual(harness.messages.count, end, "A retired recognizer cannot re-press the mouse")
            }
        }
        XCTAssertEqual(samples, 18_432)
        assertFiniteCoordinates(harness.messages)
        let settled = harness.messages.count
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(harness.messages.count, settled, "Cancelled flush tasks cannot send after the gestures end")
    }

    func testSeededTrackpadReversesImmediatelyAfterLongOvershootOnEveryScreenEdge() throws {
        let harness = Harness()
        var random = Seeded(state: 0xED6E5)
        var samples = 0
        for screen in screens {
            for cycle in 0..<128 {
                let towardRight = cycle.isMultiple(of: 2)
                let towardBottom = (cycle / 2).isMultiple(of: 2)
                let origin = CGPoint(x: towardRight ? 0.99 : 0.01,
                                     y: towardBottom ? 0.99 : 0.01)
                harness.input.placePointer(displayID: screen.id, at: origin)
                let token = UUID(), start = CGPoint(x: 0.5, y: 0.5)
                let begin = harness.messages.count
                var hand = start
                for _ in 0..<32 {
                    hand.x += (towardRight ? 1 : -1) * (0.02 + random.unit() * 0.1)
                    hand.y += (towardBottom ? 1 : -1) * (0.02 + random.unit() * 0.1)
                    let point = try screen.gesture(hand, mode: .pointer)
                    harness.input.updateGesture(token: token, displayID: screen.id, mode: .pointer,
                                                start: start, point: point, translation: .zero)
                    samples += 1
                }
                // Reverse while the hand is still far outside the rendered picture. There
                // must be no stored overshoot that the wearer has to retrace first.
                let reversal = 0.01 + random.unit() * 0.04
                hand.x -= (towardRight ? 1 : -1) * reversal
                hand.y -= (towardBottom ? 1 : -1) * reversal
                let point = try screen.gesture(hand, mode: .pointer)
                harness.input.finishGesture(token: token, displayID: screen.id, mode: .pointer,
                                            start: start, point: point, translation: .zero)
                let final = try XCTUnwrap(harness.messages.last)
                XCTAssertEqual(try XCTUnwrap(final.x), Double(towardRight ? 1 - reversal : reversal), accuracy: 1e-9)
                XCTAssertEqual(try XCTUnwrap(final.y), Double(towardBottom ? 1 - reversal : reversal), accuracy: 1e-9)
                XCTAssertTrue(harness.messages[begin...].allSatisfy { $0.displayID == screen.id && $0.action == "move" })
            }
        }
        XCTAssertEqual(samples, 16_384)
        assertFiniteCoordinates(harness.messages)
    }

    func testSeededScrollConservesTwoAxisTravelAcrossPortraitAndLandscapeScreens() throws {
        let harness = Harness()
        var random = Seeded(state: 0x5C2011)
        var samples = 0
        for screen in screens {
            for cycle in 0..<128 {
                let token = UUID(), start = CGPoint(x: 0.5, y: 0.5)
                let begin = harness.messages.count
                var translation = CGSize.zero
                harness.input.updateGesture(token: token, displayID: screen.id, mode: .scroll,
                                            start: start, point: start, translation: translation)
                for _ in 0..<32 {
                    translation.width += (cycle.isMultiple(of: 2) ? 1 : -1) * (0.2 + random.unit() * 5)
                    translation.height += (cycle.isMultiple(of: 3) ? 1 : -1) * (0.2 + random.unit() * 5)
                    let point = try screen.gesture(CGPoint(x: 0.5 + translation.width / 100,
                                                          y: 0.5 + translation.height / 100), mode: .scroll)
                    harness.input.updateGesture(token: token, displayID: screen.id, mode: .scroll,
                                                start: start, point: point, translation: translation)
                    samples += 1
                }
                harness.input.endGesture(token: token)
                let trace = harness.messages[begin...]
                let scroll = trace.filter { $0.action == "scroll" }
                XCTAssertFalse(scroll.isEmpty)
                XCTAssertEqual(scroll.reduce(0) { $0 + ($1.deltaX ?? 0) }, -Double(translation.width) * 1.4, accuracy: 0.01)
                XCTAssertEqual(scroll.reduce(0) { $0 + ($1.deltaY ?? 0) }, -Double(translation.height) * 1.4, accuracy: 0.01)
                XCTAssertTrue(trace.allSatisfy { $0.displayID == screen.id })
                XCTAssertFalse(trace.contains { $0.action == "leftDown" || $0.action == "leftUp" })
                for message in scroll {
                    XCTAssertLessThanOrEqual(abs(message.deltaX ?? 0), 500)
                    XCTAssertLessThanOrEqual(abs(message.deltaY ?? 0), 500)
                }
            }
        }
        XCTAssertEqual(samples, 16_384)
        assertFiniteCoordinates(harness.messages)
    }

    func testSeededPacingPreservesUnsaturatedScrollTravelAndLatestPointerAcrossFourDisplays() {
        var random = Seeded(state: 0xC0A1E5CE)
        var samples = 0
        for screen in screens {
            for _ in 0..<64 {
                var coalescer = InputCoalescer()
                var offered = CGPoint.zero, delivered = CGPoint.zero, last = CGPoint.zero
                var now = 100.0
                for sample in 0..<128 {
                    now += 1.0 / 240.0
                    last = random.point()
                    let x = Double((random.unit() - 0.5) * 12)
                    let y = Double((random.unit() - 0.5) * 12)
                    offered.x += CGFloat(x)
                    offered.y += CGFloat(y)
                    _ = coalescer.offer(move: last, displayID: screen.id, now: now)
                    _ = coalescer.offer(scrollX: x, scrollY: y, displayID: screen.id, now: now)
                    if sample.isMultiple(of: 4) {
                        let batch = coalescer.flush(now: now)
                        XCTAssertEqual(batch.move?.displayID, screen.id)
                        XCTAssertEqual(batch.move?.point, last)
                        if let scroll = batch.scroll {
                            XCTAssertEqual(scroll.displayID, screen.id)
                            delivered.x += CGFloat(scroll.deltaX)
                            delivered.y += CGFloat(scroll.deltaY)
                        }
                    }
                    samples += 1
                }
                let tail = coalescer.flush(now: now + InputCoalescer.interval)
                XCTAssertEqual(tail.move?.point, last)
                if let scroll = tail.scroll {
                    delivered.x += CGFloat(scroll.deltaX)
                    delivered.y += CGFloat(scroll.deltaY)
                }
                XCTAssertEqual(delivered.x, offered.x, accuracy: 0.01)
                XCTAssertEqual(delivered.y, offered.y, accuracy: 0.01)
                XCTAssertFalse(coalescer.hasPendingInput)
            }
        }
        XCTAssertEqual(samples, 32_768)
    }

    func testSaturatedScrollDrainsWithinItsBudgetAndNeverLeaksIntoTheNextDisplay() {
        var samples = 0
        for screen in screens {
            for cycle in 0..<64 {
                var coalescer = InputCoalescer()
                let direction = cycle.isMultiple(of: 2) ? 1.0 : -1.0
                for sample in 0..<128 {
                    _ = coalescer.offer(scrollX: direction * 499, scrollY: direction * 1e12,
                                        displayID: screen.id, now: Double(sample) / 10000)
                    samples += 1
                }
                var batches = 0, x = 0.0, y = 0.0
                while coalescer.hasPendingInput {
                    let batch = coalescer.flush(now: Double(batches) * InputCoalescer.interval)
                    guard let scroll = batch.scroll else { return XCTFail("An owed saturated scroll must drain") }
                    XCTAssertEqual(scroll.displayID, screen.id)
                    XCTAssertLessThanOrEqual(abs(scroll.deltaX), 500)
                    XCTAssertLessThanOrEqual(abs(scroll.deltaY), 500)
                    x += scroll.deltaX
                    y += scroll.deltaY
                    batches += 1
                    guard batches <= 4 else { return XCTFail("One flick must not leave an unbounded scroll backlog") }
                }
                XCTAssertEqual(x, direction * 2000, accuracy: 1e-9)
                XCTAssertEqual(y, direction * 2000, accuracy: 1e-9)

                _ = coalescer.offer(scrollX: 300, scrollY: 400, displayID: screen.id, now: 1)
                coalescer.discard()
                let next = screen.id % 4 + 1
                _ = coalescer.offer(scrollX: -7, scrollY: -9, displayID: next, now: 2)
                let nextBatch = coalescer.flush(now: 2)
                XCTAssertEqual(nextBatch.scroll?.displayID, next)
                XCTAssertEqual(nextBatch.scroll?.deltaX, -7)
                XCTAssertEqual(nextBatch.scroll?.deltaY, -9)
                XCTAssertFalse(coalescer.hasPendingInput)
            }
        }
        XCTAssertEqual(samples, 32_768)
    }

    private func assertFiniteCoordinates(_ messages: [DeskMessage], file: StaticString = #filePath, line: UInt = #line) {
        for message in messages {
            if let x = message.x {
                XCTAssertTrue(x.isFinite && (0...1).contains(x), file: file, line: line)
            }
            if let y = message.y {
                XCTAssertTrue(y.isFinite && (0...1).contains(y), file: file, line: line)
            }
        }
    }

    private func assertBalanced(_ messages: [DeskMessage], file: StaticString = #filePath, line: UInt = #line) {
        var held: UInt32?
        for message in messages {
            if message.action == "leftDown" {
                XCTAssertNil(held, "Two displays cannot hold the same Mac pointer", file: file, line: line)
                held = message.displayID
            } else if message.action == "leftUp" {
                XCTAssertEqual(held, message.displayID, file: file, line: line)
                held = nil
            }
        }
        XCTAssertNil(held, "Every completed or cancelled drag must release", file: file, line: line)
    }
}
