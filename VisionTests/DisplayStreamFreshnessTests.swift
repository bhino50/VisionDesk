import DeskCore
import Foundation
import XCTest
@testable import VisionDesk

/// Blocks the native worker, never the main actor, so decoding delay is deterministic.
private final class FreshnessDecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    private var shouldBlock = true

    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func beforeWork(_ kind: String) {
        guard kind == "jpeg" || kind == "video" else { return }
        lock.lock()
        let block = shouldBlock
        shouldBlock = false
        if block { entered = true }
        lock.unlock()
        if block { release.wait() }
    }
    func resume() { release.signal() }
}

@MainActor
final class DisplayStreamFreshnessTests: XCTestCase {
    private func waitFor(_ predicate: () -> Bool, file: StaticString = #filePath,
                         line: UInt = #line) async throws {
        for _ in 0..<2_000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Native decode did not reach the expected state", file: file, line: line)
    }

    func testDelayedJPEGDoesNotEnableInputAndFreshReplacementRecovers() async throws {
        try await checkDelayedFrame(video: false)
    }

    func testDelayedVideoDoesNotEnableInputAndFreshReplacementRecovers() async throws {
        try await checkDelayedFrame(video: true)
    }

    func testFramesQueuedDuringDecodeKeepTheirOwnArrivalAge() async throws {
        try await checkDelayedFrame(video: false, queueReplacement: true)
        try await checkDelayedFrame(video: true, queueReplacement: true)
    }

    private func checkDelayedFrame(video: Bool, queueReplacement: Bool = false) async throws {
        var now: TimeInterval = 100
        let gate = FreshnessDecodeGate()
        defer { gate.resume() }
        let info = DisplayInfo(id: 1, name: "Synthetic screen", width: 64, height: 64,
                               originX: 0, originY: 0, pointWidth: 64, pointHeight: 64)
        let stream = DisplayStream(info: info, now: { now }, beforeNativeWork: { gate.beforeWork($0) })
        let jpeg = try XCTUnwrap(DeskFixtures.jpeg(width: 64, height: 64))
        let frames = H264Fixture.frames
        if video {
            XCTAssertGreaterThanOrEqual(frames.count, 2)
            stream.accept(video: try XCTUnwrap(frames.first))
        } else { stream.accept(jpeg: jpeg) }
        try await waitFor { gate.hasEntered }
        if queueReplacement {
            now += 1
            if video { stream.accept(video: try XCTUnwrap(frames.dropFirst().first)) }
            else { stream.accept(jpeg: jpeg) }
        }
        let expectedArrival = now
        now += DisplayStream.freshnessInterval + 1
        gate.resume()
        try await waitFor { stream.receivedAt == expectedArrival }
        XCTAssertNotNil(stream.image)
        XCTAssertEqual(stream.receivedAt, expectedArrival)
        XCTAssertFalse(stream.isFresh(at: now), "A completed decode cannot renew an old packet")

        // A live link/control grant is insufficient while the visible frame is stale.
        let pointer = PointerInput()
        pointer.isLinked = { true }
        pointer.canControl = { _ in stream.isFresh(at: now) }
        var sent: [DeskMessage] = []
        pointer.send = { sent.append($0); return true }
        pointer.directTapClick(displayID: 1, at: CGPoint(x: 0.2, y: 0.3))
        XCTAssertTrue(sent.isEmpty)

        now += 1
        let freshArrival = now
        if video {
            let next = try XCTUnwrap(frames.dropFirst(queueReplacement ? 2 : 1).first)
            stream.accept(video: next)
        }
        else { stream.accept(jpeg: jpeg) }
        try await waitFor { stream.receivedAt == freshArrival }
        XCTAssertTrue(stream.isFresh(at: now))
        pointer.directTapClick(displayID: 1, at: CGPoint(x: 0.2, y: 0.3))
        XCTAssertEqual(sent.filter { $0.action == "leftDown" }.count, 1)
        XCTAssertEqual(sent.filter { $0.action == "leftUp" }.count, 1)
        stream.clear()
    }
}
