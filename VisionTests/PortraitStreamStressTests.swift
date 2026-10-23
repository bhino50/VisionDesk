import CoreGraphics
import DeskCore
import Foundation
import XCTest
@testable import VisionDesk

/// The work is deliberately bounded: real small JPEGs exercise native decoding, while the
/// geometry sweep covers full desktop dimensions without allocating desktop-sized bitmaps.
@MainActor
final class PortraitStreamStressTests: XCTestCase {
    func testFourThousandResizesPreservePixelsAndRejectLetterboxClicks() throws {
        var random: UInt64 = 0x5644_504F_5254_5241
        func next(_ upperBound: Int) -> Int {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return Int((random >> 32) % UInt64(upperBound))
        }
        let landmarks: [CGFloat] = [0, 0.125, 0.5, 0.875, 1]
        for iteration in 0..<4_096 {
            let short = CGFloat(320 + next(1_441))
            let long = short + CGFloat(1 + next(3_361))
            let image = iteration.isMultiple(of: 2)
                ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
            let container = CGSize(width: 320 + next(1_601), height: 240 + next(1_361))
            let rect = try XCTUnwrap(DisplayGeometry.imageRect(in: container, image: image))
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertGreaterThanOrEqual(rect.minX, -1e-8)
            XCTAssertGreaterThanOrEqual(rect.minY, -1e-8)
            XCTAssertLessThanOrEqual(rect.maxX, container.width + 1e-8)
            XCTAssertLessThanOrEqual(rect.maxY, container.height + 1e-8)
            XCTAssertEqual(rect.width / rect.height, image.width / image.height, accuracy: 1e-9)

            // Samples through the actual visible rectangle must land back on the same
            // source fraction, including all four edges after portrait/landscape changes.
            for fraction in landmarks {
                let location = CGPoint(x: rect.minX + rect.width * fraction,
                                       y: rect.minY + rect.height * (1 - fraction))
                let hit = try XCTUnwrap(DisplayGeometry.normalized(location, in: container, image: image))
                XCTAssertEqual(hit.x, fraction, accuracy: 1e-9)
                XCTAssertEqual(hit.y, 1 - fraction, accuracy: 1e-9)
            }
            let outside = rect.minX > 0.001
                ? CGPoint(x: rect.minX / 2, y: rect.midY)
                : CGPoint(x: rect.midX, y: rect.minY - 1)
            XCTAssertNil(DisplayGeometry.normalized(outside, in: container, image: image))
            let clamped = try XCTUnwrap(DisplayGeometry.normalized(outside, in: container,
                                                                  image: image, clampToImage: true))
            XCTAssertTrue((0...1).contains(clamped.x) && (0...1).contains(clamped.y))

            let sizing = try XCTUnwrap(DisplayGeometry.windowSizing(image: image))
            let requested = try XCTUnwrap(DisplayGeometry.imageRect(in: sizing.preferred, image: image))
            XCTAssertEqual(requested.size.width, sizing.preferred.width, accuracy: 1e-8)
            XCTAssertEqual(requested.size.height, sizing.preferred.height, accuracy: 1e-8)
            XCTAssertLessThanOrEqual(sizing.minimum.width, sizing.preferred.width)
            XCTAssertLessThanOrEqual(sizing.minimum.height, sizing.preferred.height)
            XCTAssertEqual(sizing.minimum.width / sizing.minimum.height,
                           image.width / image.height, accuracy: 1e-9)
        }
    }

    func testEightyBlockedDecodeRotationsDiscardBacklogsAndRestoreOnlyCurrentPixels() async throws {
        var now: TimeInterval = 100
        let gate = PortraitDecodeGate()
        let portrait = try XCTUnwrap(DeskFixtures.jpeg(width: 48, height: 80))
        let landscape = try XCTUnwrap(DeskFixtures.jpeg(width: 80, height: 48))
        let stream = DisplayStream(info: info(id: 1, portrait: false), now: { now },
                                   beforeNativeWork: { gate.beforeWork($0) })
        defer { gate.resume(); stream.clear() }
        for cycle in 0..<80 {
            let beginsPortrait = cycle.isMultiple(of: 2)
            stream.update(info: info(id: 1, portrait: beginsPortrait))
            gate.arm()
            stream.accept(jpeg: beginsPortrait ? portrait : landscape)
            try await Loopback.waitUntil { gate.hasEntered }
            // A burst arrives while one native call is blocked; repeated rotations must
            // invalidate that call and every superseded pending frame without more workers.
            for update in 0..<128 {
                stream.accept(jpeg: beginsPortrait ? portrait : landscape)
                if update.isMultiple(of: 16) {
                    stream.update(info: info(id: 1, portrait: update.isMultiple(of: 32)))
                }
            }
            stream.update(info: info(id: 1, portrait: !beginsPortrait))
            XCTAssertNil(stream.image)
            XCTAssertFalse(stream.isFresh(at: now))
            now += DisplayStream.freshnessInterval + 1
            let arrival = now
            stream.accept(jpeg: beginsPortrait ? landscape : portrait)
            gate.resume()
            let expected = beginsPortrait ? CGSize(width: 80, height: 48) : CGSize(width: 48, height: 80)
            try await Loopback.waitUntil { stream.receivedAt == arrival && stream.imageSize == expected }
            XCTAssertTrue(stream.isFresh(at: now))
            XCTAssertNil(stream.decodeWarning)
            now += DisplayStream.freshnessInterval
            XCTAssertFalse(stream.isFresh(at: now), "An unchanged picture must age out after every rotation.")
        }
        XCTAssertEqual(gate.enteredCount, 80)
    }

    func testFourDisplaysSurviveFortyIndependentRotationsAndRepeatedHotplug() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        let model = session.model
        var infos = (1...4).map { info(id: UInt32($0), portrait: $0.isMultiple(of: 2)) }
        let portrait = try XCTUnwrap(DeskFixtures.jpeg(width: 48, height: 80))
        let landscape = try XCTUnwrap(DeskFixtures.jpeg(width: 80, height: 48))
        // The session is authenticated normally. Decoded messages are delivered directly to
        // the same guarded production handler so each metadata/frame boundary is observable.
        model.receive(DeskMessage(kind: "status", status: "Synthetic control enabled", controlEnabled: true))
        model.receive(DeskMessage(kind: "displays", displays: infos))
        func feedAll() {
            for item in infos {
                model.receive(DeskMessage(kind: "frame", displayID: item.id,
                                          jpeg: item.height > item.width ? portrait : landscape))
            }
        }
        func receiveContinuingFramesUntilAllScreensRecover(cycle: Int) async throws {
            // Native work has four non-waiting admission slots. A removed stream can still
            // be retiring while its replacement arrives, so a single burst is allowed to
            // shed a JPEG. Model a continuing source and require every screen to recover
            // within two seconds; never make the production worker cap larger for a test.
            for _ in 0..<120 {
                feedAll()
                try await Task.sleep(for: .milliseconds(16))
                if infos.allSatisfy({ model.canControl(displayID: $0.id) }) { return }
            }
            let state = infos.map { item in
                let stream = model.display(id: item.id)
                return "\(item.id): image=\(stream?.image != nil), fresh=\(stream?.isFresh() == true)"
            }.joined(separator: "; ")
            XCTFail("Continuing frames did not restore every screen after cycle \(cycle): \(state)")
            throw Loopback.WaitError.timeout
        }
        try await receiveContinuingFramesUntilAllScreensRecover(cycle: -1)
        for cycle in 0..<40 {
            let index = cycle % 4, target = infos[index].id
            let existing = try infos.map { try XCTUnwrap(model.display(id: $0.id)) }
            if cycle.isMultiple(of: 5) {
                model.receive(DeskMessage(kind: "displays", displays: infos.filter { $0.id != target }))
                XCTAssertNil(model.display(id: target))
                XCTAssertNil(existing[index].image)
                XCTAssertFalse(model.canControl(displayID: target))
            }
            infos[index] = info(id: target, portrait: infos[index].width > infos[index].height)
            model.receive(DeskMessage(kind: "displays", displays: infos))
            let changed = try XCTUnwrap(model.display(id: target))
            XCTAssertNil(changed.image)
            XCTAssertFalse(model.canControl(displayID: target))
            if !cycle.isMultiple(of: 5) { XCTAssertTrue(changed === existing[index]) }
            for other in 0..<4 where other != index {
                XCTAssertTrue(model.display(id: infos[other].id) === existing[other])
                XCTAssertNotNil(existing[other].image, "Rotating one screen cannot blank another.")
            }
            try await receiveContinuingFramesUntilAllScreensRecover(cycle: cycle)
            for item in infos {
                let stream = try XCTUnwrap(model.display(id: item.id))
                XCTAssertEqual(stream.imageSize, item.height > item.width
                               ? CGSize(width: 48, height: 80) : CGSize(width: 80, height: 48))
            }
        }
        let retired = model.displays
        model.disconnect()
        XCTAssertTrue(model.displays.isEmpty)
        XCTAssertTrue(retired.allSatisfy { $0.image == nil && !$0.isFresh() })
    }

    private func info(id: UInt32, portrait: Bool) -> DisplayInfo {
        DisplayInfo(id: id, name: "Synthetic screen \(id)", width: portrait ? 1_080 : 1_800,
                    height: portrait ? 1_800 : 1_080, originX: Double(id - 1) * 1_800,
                    originY: 0, pointWidth: portrait ? 540 : 900, pointHeight: portrait ? 900 : 540)
    }
}

private final class PortraitDecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: DispatchSemaphore?
    private var blocked: DispatchSemaphore?
    private var count = 0

    var enteredCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return blocked != nil }

    func arm() {
        lock.lock(); defer { lock.unlock() }
        precondition(armed == nil && blocked == nil)
        armed = DispatchSemaphore(value: 0)
    }

    func beforeWork(_ kind: String) {
        guard kind == "jpeg" else { return }
        lock.lock()
        let semaphore = armed
        if semaphore != nil { armed = nil; blocked = semaphore; count += 1 }
        lock.unlock()
        semaphore?.wait()
    }

    func resume() {
        lock.lock()
        // A timeout can leave work admitted but not yet inside the hook. Disarm and signal
        // that pending gate too, so a late native worker cannot hang after the test exits.
        let semaphore = blocked ?? armed
        blocked = nil
        armed = nil
        lock.unlock()
        semaphore?.signal()
    }
}
