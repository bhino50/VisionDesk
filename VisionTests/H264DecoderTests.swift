import DeskCore
import Foundation
import UIKit
import XCTest
@testable import VisionDesk

/// The recorded H.264 fixture: four 64x64 synthetic-colour access units produced by the
/// production `H264Encoder` on a Mac and verified to decode through the production
/// `H264Decoder`, in the shape `MakeFixture.swift` prints (keyframe, two predicted, keyframe).
///
/// It is embedded as a string rather than a bundle resource so the visionOS test target needs
/// no resource phase. Regenerate with `Tests/HardwareVideoChecks/MakeFixture.swift` and paste
/// its stdout over `json` below; nothing else in this file has to change.
///
enum H264Fixture {
    static let json = #"""
    [{"width":64,"pps":"KO48sA==","sps":"J2QAFKxWgw3gQYRQ","sequence":0,"isKeyframe":true,"height":64,"payload":"AAAANgYFLUdWStxcTEM\/lO\/FETzRQ6gBAAADAAQDAAADAAUCABbjYAsAAAMAAAMAAAMBkAwDkTABgAAAAEEluCAB3834HufnTRhHV\/3zZOeeu90UgFbr+N+aT+7mhA22qEQSYQjLB6jOvHDYFv75iIQAAQ+HDoMAGzCC5hMF1A=="},{"sequence":1,"height":64,"width":64,"isKeyframe":false,"payload":"AAAALyHhBEEfzK\/wPcpr\/8JM3f+FSOvHEd7UiT\/47Mi\/9zSyLCZOvd2W6QYwIqc7NcTU"},{"width":64,"sequence":2,"isKeyframe":false,"height":64,"payload":"AAAAMCHiCEFP1c38F25nf\/hJGH\/1\/zeW59z2qEprTJWn5AeJMQt7ZQoc6EPYKFLtQum\/rA=="},{"width":64,"pps":"KO48sA==","sps":"J2QAFKxWgw3gQYRQ","sequence":3,"isKeyframe":true,"height":64,"payload":"AAAAGgYFFUdWStxcTEM\/lO\/FETzRQ6gDAAADAAWAAAAAPSW4EAAr\/+T\/BeD+9DjpP++1CeQ6YMFy0Zum+aWnYUfUm2z5YTznEpekslaelX0Of2HawAA2oAjfwD9Bbo4="}]
    """#

    static var frames: [EncodedVideoFrame] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([EncodedVideoFrame].self, from: data) else { return [] }
        return decoded
    }

    static var isAvailable: Bool { !frames.isEmpty }

    static let unavailableReason = """
        No validated H.264 fixture is embedded. `.build/h264-fixture.json` was empty; \
        rerun Tests/HardwareVideoChecks/MakeFixture.swift on a Mac and paste its stdout into \
        H264Fixture.json in VisionTests/H264DecoderTests.swift.
        """
}

/// Bytes that satisfy `EncodedVideoFrame.isValid` but are not a real bitstream.
///
/// These exist only to drive production failure and admission paths: a frame built here is
/// expected to reach the decoder and fail there. No test asserts that one of these decodes.
enum SyntheticUnit {
    static func nalUnit(type: UInt8, byteCount: Int = 24) -> Data {
        Data([type & 0x1F]) + Data(repeating: 0x5A, count: byteCount - 1)
    }

    static func avcc(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { buffer, unit in
            let length = UInt32(unit.count)
            buffer.append(contentsOf: [
                UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)
            ])
            buffer.append(unit)
        }
    }

    /// Structurally a keyframe, undecodable in fact.
    static func undecodableKeyframe(sequence: UInt64, width: Int = 64, height: Int = 64) -> EncodedVideoFrame {
        EncodedVideoFrame(
            width: width, height: height, sequence: sequence, isKeyframe: true,
            payload: avcc([nalUnit(type: 5)]),
            sps: nalUnit(type: 7, byteCount: 10), pps: nalUnit(type: 8, byteCount: 5)
        )
    }

    /// Structurally a predicted frame, undecodable in fact.
    static func undecodablePredicted(sequence: UInt64, width: Int = 64, height: Int = 64) -> EncodedVideoFrame {
        EncodedVideoFrame(
            width: width, height: height, sequence: sequence, isKeyframe: false,
            payload: avcc([nalUnit(type: 1)])
        )
    }

    /// Fails `isValid` outright: an empty payload is never a NAL unit sequence.
    static func malformed(sequence: UInt64) -> EncodedVideoFrame {
        EncodedVideoFrame(width: 64, height: 64, sequence: sequence, isKeyframe: false, payload: Data())
    }
}

// MARK: - Decoder

final class H264DecoderTests: XCTestCase {

    func testDecoderRejectsAFrameThatFailsWireValidation() {
        let decoder = H264Decoder()
        defer { decoder.invalidate() }
        XCTAssertNil(decoder.decode(SyntheticUnit.malformed(sequence: 0)))
    }

    /// A predicted frame arriving first has no session and no reference picture behind it.
    func testDecoderCannotDecodeAPredictedFrameWithoutASession() {
        let decoder = H264Decoder()
        defer { decoder.invalidate() }
        XCTAssertNil(decoder.decode(SyntheticUnit.undecodablePredicted(sequence: 0)))
    }

    /// Parameter sets can pass the wire check and still not describe a stream VideoToolbox can
    /// build a session from. The decoder must report that as no picture, not crash or guess.
    func testDecoderReturnsNilForAKeyframeWithUnusableParameterSets() {
        let decoder = H264Decoder()
        defer { decoder.invalidate() }
        let frame = SyntheticUnit.undecodableKeyframe(sequence: 0)
        XCTAssertTrue(frame.isValid, "the frame must clear wire validation so the decoder is what rejects it")
        XCTAssertNil(decoder.decode(frame))
    }

    func testDecoderToleratesRepeatedResetAndInvalidate() {
        let decoder = H264Decoder()
        decoder.reset()
        decoder.reset()
        decoder.invalidate()
        decoder.invalidate()
        XCTAssertNil(decoder.decode(SyntheticUnit.undecodableKeyframe(sequence: 0)))
    }

    // MARK: Fixture-backed decodes

    func testDecodesEveryFixtureFrameInSubmissionOrder() throws {
        try XCTSkipUnless(H264Fixture.isAvailable, H264Fixture.unavailableReason)
        let frames = H264Fixture.frames
        let decoder = H264Decoder()
        defer { decoder.invalidate() }
        for frame in frames {
            let image = try XCTUnwrap(decoder.decode(frame), "frame \(frame.sequence) must decode")
            XCTAssertEqual(image.width, frame.width)
            XCTAssertEqual(image.height, frame.height)
        }
    }

    func testFixtureIsAKeyframeLedChainEndingInAKeyframe() throws {
        try XCTSkipUnless(H264Fixture.isAvailable, H264Fixture.unavailableReason)
        let frames = H264Fixture.frames
        XCTAssertTrue(frames.allSatisfy(\.isValid))
        XCTAssertEqual(frames.map(\.sequence), Array(0..<UInt64(frames.count)))
        XCTAssertEqual(frames.first?.isKeyframe, true)
        XCTAssertEqual(frames.last?.isKeyframe, true)
        XCTAssertTrue(frames.allSatisfy { $0.isKeyframe == ($0.sps != nil && $0.pps != nil) })
    }

    /// A predicted frame is meaningless once the session holding its references is gone.
    func testPredictedFrameIsRejectedAfterResetUntilTheNextKeyframe() throws {
        try XCTSkipUnless(H264Fixture.isAvailable, H264Fixture.unavailableReason)
        let frames = H264Fixture.frames
        let keyframe = try XCTUnwrap(frames.first { $0.isKeyframe })
        let predicted = try XCTUnwrap(frames.first { !$0.isKeyframe })
        let decoder = H264Decoder()
        defer { decoder.invalidate() }

        XCTAssertNotNil(decoder.decode(keyframe))
        XCTAssertNotNil(decoder.decode(predicted))
        decoder.reset()
        XCTAssertNil(decoder.decode(predicted), "a reset decoder has no reference to predict from")
        XCTAssertNotNil(decoder.decode(keyframe), "a keyframe must rebuild the session")
    }

    func testInvalidatedDecoderRefusesAFrameItPreviouslyDecoded() throws {
        try XCTSkipUnless(H264Fixture.isAvailable, H264Fixture.unavailableReason)
        let keyframe = try XCTUnwrap(H264Fixture.frames.first { $0.isKeyframe })
        let decoder = H264Decoder()
        XCTAssertNotNil(decoder.decode(keyframe))
        decoder.invalidate()
        XCTAssertNil(decoder.decode(keyframe), "invalidate is permanent")
    }
}

// MARK: - DisplayStream

@MainActor
final class DisplayStreamVideoTests: XCTestCase {

    private func info(id: UInt32 = 1, width: Int = 64, height: Int = 64) -> DisplayInfo {
        DisplayInfo(
            id: id, name: "Test", width: width, height: height,
            originX: 0, originY: 0, pointWidth: Double(width), pointHeight: Double(height)
        )
    }

    /// A genuinely encoded JPEG, so the still path exercises a real decode rather than a stub.
    private func jpeg(width: Int = 64, height: Int = 64) throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    /// Lets the stream's main-actor decode tasks run until `condition` holds.
    private func wait(
        upTo seconds: TimeInterval = 5, for description: String,
        until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    // MARK: Initial state

    func testStreamStartsWithNoPictureAndNeedsAKeyframe() {
        let stream = DisplayStream(info: info())
        XCTAssertNil(stream.image)
        XCTAssertNil(stream.receivedAt)
        XCTAssertNil(stream.decodeWarning)
        XCTAssertTrue(stream.needsKeyframe)
        XCTAssertFalse(stream.isFresh())
    }

    // MARK: Admission, observed through the stream

    func testPredictedFrameBeforeAnyKeyframeAsksForOneAndShowsNothing() {
        let stream = DisplayStream(info: info())
        var requests = 0
        stream.onKeyframeNeeded = { requests += 1 }

        stream.accept(video: SyntheticUnit.undecodablePredicted(sequence: 0))

        XCTAssertGreaterThan(requests, 0)
        XCTAssertTrue(stream.needsKeyframe)
        XCTAssertNil(stream.image)
        XCTAssertFalse(stream.isFresh())
    }

    /// A malformed unit demands a keyframe only from a stream that is actually on video: that
    /// is the stream with a reference chain the sender may have advanced past. A stream still
    /// being served by images has no chain, so it is warned and otherwise left alone — the
    /// `testMalformedVideo…ServedByJPEG` regressions below cover that half.
    ///
    /// Video mode is therefore established first, with a unit that clears wire validation and
    /// fails in the decoder. The request callback is installed afterwards so the count can
    /// only be attributed to the malformed frame. No await anywhere: the decode task cannot
    /// interleave, so the warning asserted here is the admission refusal rather than the
    /// decode failure that follows it.
    func testMalformedFrameAfterAVideoKeyframeWarnsAndAsksForAKeyframe() {
        let stream = DisplayStream(info: info())
        stream.accept(video: SyntheticUnit.undecodableKeyframe(sequence: 0))
        XCTAssertTrue(stream.usesVideo, "the stream has to be on video for this to be its path")

        var requests = 0
        stream.onKeyframeNeeded = { requests += 1 }

        stream.accept(video: SyntheticUnit.malformed(sequence: 1))

        XCTAssertEqual(stream.decodeWarning, "The Mac sent an unsupported frame.")
        XCTAssertGreaterThan(requests, 0, "an established video stream asks to resynchronize")
        XCTAssertTrue(stream.needsKeyframe)
        XCTAssertNil(stream.receivedAt, "a broken chain revokes freshness immediately")
        XCTAssertFalse(stream.isFresh())
    }

    /// A duplicate is dropped in silence: nothing to show, nothing to ask for.
    func testStaleFrameIsIgnoredWithoutWarningOrKeyframeRequest() {
        let stream = DisplayStream(info: info())
        stream.accept(video: SyntheticUnit.undecodableKeyframe(sequence: 0))
        var requests = 0
        stream.onKeyframeNeeded = { requests += 1 }
        let warningBefore = stream.decodeWarning

        // No await between these two calls, so no decode can interleave and change the counts.
        stream.accept(video: SyntheticUnit.undecodableKeyframe(sequence: 0))

        XCTAssertEqual(requests, 0)
        XCTAssertEqual(stream.decodeWarning, warningBefore)
    }

    /// Shedding the backlog costs one keyframe and returns the viewer to live.
    func testOverflowingThePendingQueueShedsTheBacklogAndAsksForAKeyframe() {
        let stream = DisplayStream(info: info())
        var requests = 0
        stream.onKeyframeNeeded = { requests += 1 }

        stream.accept(video: SyntheticUnit.undecodableKeyframe(sequence: 0))
        for sequence in 1...UInt64(DisplayStream.maximumPendingVideoFrames) {
            stream.accept(video: SyntheticUnit.undecodablePredicted(sequence: sequence))
        }

        XCTAssertGreaterThan(requests, 0, "the queue must overflow and demand a keyframe")
        XCTAssertTrue(stream.needsKeyframe)
    }

    // MARK: Freshness follows a successful decode, never a failed one

    func testSuccessfulDecodePublishesAPictureAndMakesTheStreamFresh() async throws {
        let stream = DisplayStream(info: info())
        stream.accept(jpeg: try jpeg())
        await wait(for: "the decoded picture") { stream.image != nil }

        XCTAssertNotNil(stream.receivedAt)
        XCTAssertNil(stream.decodeWarning)
        XCTAssertTrue(stream.isFresh())
    }

    /// A malformed video message must not cost a screen that images are serving correctly.
    ///
    /// The stream is on JPEG, so there is no reference chain for the bad unit to have broken
    /// and nothing for the stream to wait for. Revoking freshness here would disable control
    /// on a live screen on the strength of one unusable message, and taking the source over
    /// would hand the stream to a video pipeline that has never decoded anything.
    func testMalformedVideoDoesNotDisturbAStreamBeingServedByJPEG() async throws {
        let stream = DisplayStream(info: info())
        stream.accept(jpeg: try jpeg())
        await wait(for: "the decoded picture") { stream.image != nil }
        let stampedAt = try XCTUnwrap(stream.receivedAt)

        stream.accept(video: SyntheticUnit.malformed(sequence: 0))

        XCTAssertEqual(stream.decodeWarning, "The Mac sent an unsupported frame.",
                       "the refusal is still reported")
        XCTAssertFalse(stream.usesVideo, "an unusable payload is not a source transition")
        XCTAssertNotNil(stream.image)
        XCTAssertEqual(stream.receivedAt, stampedAt, "a live still picture keeps its stamp")
        XCTAssertTrue(stream.isFresh(), "control may not be revoked by one malformed message")
    }

    /// Nor may it cancel a still frame that is mid-decode. The switch and the decode race on
    /// this actor, so the refusal has to be decided before the source can change under it.
    func testMalformedVideoCannotCancelAJPEGDecodeInFlight() async throws {
        let stream = DisplayStream(info: info())
        // No await in between: the decode is certainly outstanding when the bad unit lands.
        stream.accept(jpeg: try jpeg())
        stream.accept(video: SyntheticUnit.malformed(sequence: 0))

        await wait(for: "the in-flight JPEG to publish anyway") { stream.image != nil }
        XCTAssertFalse(stream.usesVideo)
        XCTAssertNotNil(stream.receivedAt)
        XCTAssertTrue(stream.isFresh())
    }

    /// The other half: a stream that *is* on video has a reference chain, and a malformed unit
    /// may have advanced the sender's. That stream keeps its picture for context but gives up
    /// its freshness and waits for a keyframe — the recovery behaviour the JPEG case has no
    /// use for. A real decoded keyframe is needed to make the stream genuinely fresh first.
    func testMalformedVideoOnAVideoStreamRevokesFreshnessAndDemandsAKeyframe() async throws {
        try XCTSkipUnless(H264Fixture.isAvailable, H264Fixture.unavailableReason)
        let first = try XCTUnwrap(H264Fixture.frames.first)
        let stream = DisplayStream(info: info(width: first.width, height: first.height))
        stream.accept(video: first)
        await wait(for: "the decoded keyframe") { stream.isFresh() }
        var requests = 0
        stream.onKeyframeNeeded = { requests += 1 }

        stream.accept(video: SyntheticUnit.malformed(sequence: first.sequence &+ 1))

        XCTAssertTrue(stream.usesVideo)
        XCTAssertNil(stream.receivedAt, "a broken chain must immediately revoke freshness")
        XCTAssertFalse(stream.isFresh(), "control must wait for a valid keyframe")
        XCTAssertNotNil(stream.image, "the last good picture is kept for context")
        XCTAssertEqual(stream.decodeWarning, "The Mac sent an unsupported frame.")
        XCTAssertTrue(stream.needsKeyframe)
        XCTAssertGreaterThan(requests, 0, "a video stream still asks for its resynchronization")
    }

    func testStreamIsNotFreshOnceItsPictureHasAgedOut() async throws {
        let stream = DisplayStream(info: info())
        stream.accept(jpeg: try jpeg())
        await wait(for: "the decoded picture") { stream.image != nil }
        let stampedAt = try XCTUnwrap(stream.receivedAt)

        XCTAssertTrue(stream.isFresh(at: stampedAt + 2.0))
        XCTAssertFalse(stream.isFresh(at: stampedAt + 2.5))
        XCTAssertFalse(stream.isFresh(at: stampedAt + 60))
    }

    func testVideoOverloadKeepsThePictureButBlocksControlUntilAKeyframeRecovers() async throws {
        XCTAssertTrue(H264Fixture.isAvailable, H264Fixture.unavailableReason)
        let frames = H264Fixture.frames
        let stream = DisplayStream(info: info())
        stream.accept(video: try XCTUnwrap(frames.first))
        await wait(for: "the initial video picture") { stream.isFresh() }
        let picture = try XCTUnwrap(stream.image)
        let predicted = try XCTUnwrap(frames.first { !$0.isKeyframe })
        for sequence in 1...UInt64(DisplayStream.maximumPendingVideoFrames + 1) {
            var frame = predicted
            frame.sequence = sequence
            stream.accept(video: frame)
        }
        XCTAssertTrue(stream.image === picture, "overload must keep the last picture instead of flashing black")
        XCTAssertNil(stream.receivedAt)
        XCTAssertFalse(stream.isFresh())
        XCTAssertTrue(stream.needsKeyframe)
        var recovery = try XCTUnwrap(frames.last)
        recovery.sequence = UInt64(DisplayStream.maximumPendingVideoFrames + 2)
        stream.accept(video: recovery)
        await wait(for: "keyframe recovery after overload") { stream.isFresh() }
        XCTAssertFalse(stream.needsKeyframe)
        for _ in 0..<50 { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(stream.isFresh(), "old decode results cannot disturb the recovered stream")
    }

    /// A failure keeps context visible, but never vouches for the old picture as current input.
    func testFailedVideoDecodeKeepsContextButRevokesInputAndAsksForAKeyframe() async throws {
        let stream = DisplayStream(info: info())

        // Record the geometry first, so the second keyframe is admitted without a pipeline
        // reset and the only thing that can drop the picture is the decode failure itself.
        stream.accept(video: SyntheticUnit.undecodableKeyframe(sequence: 0))
        await wait(for: "the first decode to fail") { stream.decodeWarning != nil }

        stream.accept(jpeg: try jpeg())
        await wait(for: "the decoded picture") { stream.image != nil }
        XCTAssertTrue(stream.isFresh())
        let previousPicture = stream.image

        var requests = 0
        stream.onKeyframeNeeded = { requests += 1 }
        stream.accept(video: SyntheticUnit.undecodableKeyframe(sequence: 1))
        await wait(for: "the failed decode") { stream.decodeWarning != nil }

        XCTAssertTrue(stream.image === previousPicture)
        XCTAssertNil(stream.receivedAt)
        XCTAssertFalse(stream.isFresh())
        XCTAssertTrue(stream.needsKeyframe)
        XCTAssertGreaterThan(requests, 0)
        XCTAssertEqual(stream.decodeWarning, "A frame could not be displayed.")
    }

    func testAStalledVideoScreenRequestsRecoveryWithoutMakingItsOldPictureFresh() async throws {
        let first = try XCTUnwrap(H264Fixture.frames.first)
        let stream = DisplayStream(info: info(width: first.width, height: first.height))
        stream.accept(video: first)
        await wait(for: "initial picture") { stream.isFresh() }
        let stamp = try XCTUnwrap(stream.receivedAt)
        let picture = stream.image
        var requests = 0
        stream.onKeyframeNeeded = { requests += 1 }
        stream.requestRefreshIfStalled(at: stamp + 1)
        XCTAssertEqual(requests, 0)
        stream.requestRefreshIfStalled(at: stamp + DisplayStream.freshnessInterval)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(stream.receivedAt, stamp)
        XCTAssertTrue(stream.image === picture)
        XCTAssertFalse(stream.isFresh(at: stamp + DisplayStream.freshnessInterval))
    }

    // MARK: Source transitions

    /// A real session uses both screen sources. The Mac sends a cached JPEG for every display
    /// the moment a client attaches and only moves to H.264 once it knows the client's codec,
    /// and a display whose hardware encoder fails latches back to JPEG for good. So a decode
    /// belonging to the source being retired can still be in flight at the switch, and its
    /// older picture must not land on top of the newer source's answer — nor refresh the stamp
    /// that decides whether this screen accepts input.
    ///
    /// The geometry is recorded first on purpose: the second keyframe is then admitted without
    /// a pipeline reset, so the only thing that can orphan the JPEG is the source switch
    /// itself rather than a geometry change that would have reset the pipeline anyway.
    func testAJPEGDecodeInFlightAtAVideoSwitchCannotPublishAfterIt() async throws {
        let stream = DisplayStream(info: info())
        stream.accept(video: SyntheticUnit.undecodableKeyframe(sequence: 0))
        await wait(for: "the geometry-recording decode to fail") { stream.decodeWarning != nil }
        XCTAssertTrue(stream.usesVideo)

        // No await between these two calls, so the JPEG decode is certainly still outstanding
        // when video takes the stream back.
        stream.accept(jpeg: try jpeg())
        XCTAssertFalse(stream.usesVideo, "the last source to be accepted owns the stream")
        stream.accept(video: SyntheticUnit.undecodableKeyframe(sequence: 1))
        XCTAssertTrue(stream.usesVideo)

        await wait(for: "the video pipeline's own answer") {
            stream.decodeWarning == "A frame could not be displayed."
        }
        // Give the orphaned JPEG decode every chance to publish before asserting it cannot.
        for _ in 0..<50 { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNil(stream.image, "a decode orphaned by a source switch may not publish after it")
        XCTAssertNil(stream.receivedAt, "nor may it refresh the stamp that re-enables control")
        XCTAssertFalse(stream.isFresh())
        XCTAssertTrue(stream.needsKeyframe)
    }

    /// The retired pipeline has to stay usable. An orphaned task returns on its epoch check
    /// without clearing its own handle, so a switch that bumped the epoch and left
    /// `decodeTask` set would make `guard decodeTask == nil` refuse every later still frame
    /// for the life of the stream — a display that goes quiet for good rather than failing
    /// visibly. This is the JPEG fallback a Mac drops to when its encoder dies, so it is the
    /// path that has to work after video has had the stream.
    func testAJPEGAcceptedAfterAVideoStretchStillDecodesAndRestoresFreshness() async throws {
        let stream = DisplayStream(info: info())
        stream.accept(jpeg: try jpeg())
        // Again no await: the switch happens while the first still frame is mid-decode.
        stream.accept(video: SyntheticUnit.undecodableKeyframe(sequence: 0))
        await wait(for: "the video decode to fail") {
            stream.image == nil && stream.decodeWarning != nil
        }

        stream.accept(jpeg: try jpeg())
        await wait(for: "the JPEG pipeline to publish again") { stream.image != nil }
        XCTAssertFalse(stream.usesVideo)
        XCTAssertNil(stream.decodeWarning)
        XCTAssertNotNil(stream.receivedAt)
        XCTAssertTrue(stream.isFresh(), "a still frame re-enables control after a failed video switch")
    }

    // MARK: Epoch and reset

    /// `clear()` bumps the epoch mid-decode. The in-flight result belongs to the old epoch and
    /// must not resurrect a picture the stream has already taken down.
    func testClearDuringAnInFlightDecodeDiscardsThatDecodesResult() async throws {
        let stream = DisplayStream(info: info())
        stream.accept(jpeg: try jpeg())
        // No await in between: the decode is still pending when the epoch moves.
        stream.clear()

        XCTAssertNil(stream.image)
        XCTAssertTrue(stream.needsKeyframe)

        // Give the orphaned task every chance to publish before asserting that it cannot.
        for _ in 0..<50 { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNil(stream.image, "a pre-clear decode must not repopulate the picture")
        XCTAssertNil(stream.receivedAt)
        XCTAssertFalse(stream.isFresh())
    }

    func testClearDropsThePictureWarningAndSequencerState() async throws {
        let stream = DisplayStream(info: info())
        stream.accept(jpeg: try jpeg())
        await wait(for: "the decoded picture") { stream.image != nil }
        stream.accept(video: SyntheticUnit.malformed(sequence: 0))
        XCTAssertNotNil(stream.decodeWarning)

        stream.clear()

        XCTAssertNil(stream.image)
        XCTAssertNil(stream.receivedAt)
        XCTAssertNil(stream.decodeWarning)
        XCTAssertTrue(stream.needsKeyframe)
        XCTAssertFalse(stream.isFresh())
    }

    /// After a clear the sequencer is back to its initial state, so a predicted frame that
    /// would once have been in order is now rejected until a keyframe arrives.
    func testClearMakesTheStreamRequireAKeyframeAgain() {
        let stream = DisplayStream(info: info())
        stream.accept(video: SyntheticUnit.undecodableKeyframe(sequence: 0))
        stream.clear()

        var requests = 0
        stream.onKeyframeNeeded = { requests += 1 }
        stream.accept(video: SyntheticUnit.undecodablePredicted(sequence: 1))

        XCTAssertGreaterThan(requests, 0, "a cleared stream has nothing to predict from")
        XCTAssertTrue(stream.needsKeyframe)
    }

    /// A resize invalidates the cached bitmap: it has the old aspect ratio, and `isFresh()`
    /// vouching for it would map taps to the wrong place on the Mac.
    func testResizingTheDisplayDropsTheCachedPicture() async throws {
        let stream = DisplayStream(info: info())
        stream.accept(jpeg: try jpeg())
        await wait(for: "the decoded picture") { stream.image != nil }

        stream.update(info: info(width: 128, height: 96))

        XCTAssertNil(stream.image)
        XCTAssertNil(stream.receivedAt)
        XCTAssertFalse(stream.isFresh())
        XCTAssertTrue(stream.needsKeyframe)
        XCTAssertEqual(stream.imageSize, CGSize(width: 128, height: 96))
    }

    /// Point size can move without the pixel grid moving, and the bitmap is still correct.
    func testUpdatingOnlyThePointSizeKeepsTheCachedPicture() async throws {
        let stream = DisplayStream(info: info())
        stream.accept(jpeg: try jpeg())
        await wait(for: "the decoded picture") { stream.image != nil }
        let stampedAt = try XCTUnwrap(stream.receivedAt)

        var resized = info()
        resized.pointWidth = 200
        resized.pointHeight = 150
        stream.update(info: resized)

        XCTAssertNotNil(stream.image)
        XCTAssertEqual(stream.receivedAt, stampedAt)
        XCTAssertTrue(stream.isFresh())
    }

    // MARK: Fixture-backed stream behaviour

    func testStreamPublishesAPictureOnlyAfterTheFixtureActuallyDecodes() async throws {
        try XCTSkipUnless(H264Fixture.isAvailable, H264Fixture.unavailableReason)
        let frames = H264Fixture.frames
        let first = try XCTUnwrap(frames.first)
        let stream = DisplayStream(info: info(width: first.width, height: first.height))

        XCTAssertFalse(stream.isFresh(), "nothing is fresh before a decode succeeds")
        stream.accept(video: first)
        await wait(for: "the decoded keyframe") { stream.image != nil }

        XCTAssertFalse(stream.needsKeyframe, "a successful decode clears the keyframe demand")
        XCTAssertNil(stream.decodeWarning)
        XCTAssertTrue(stream.isFresh())
        XCTAssertEqual(stream.image?.size, CGSize(width: first.width, height: first.height))
    }

    func testStreamDecodesTheWholeFixtureChainAndStaysFresh() async throws {
        try XCTSkipUnless(H264Fixture.isAvailable, H264Fixture.unavailableReason)
        let frames = H264Fixture.frames
        let first = try XCTUnwrap(frames.first)
        let stream = DisplayStream(info: info(width: first.width, height: first.height))

        for frame in frames {
            let previousStamp = stream.receivedAt
            stream.accept(video: frame)
            await wait(for: "frame \(frame.sequence) to decode") { stream.receivedAt != nil && stream.receivedAt != previousStamp }
        }

        XCTAssertNil(stream.decodeWarning)
        XCTAssertFalse(stream.needsKeyframe)
        XCTAssertTrue(stream.isFresh())
    }

    /// A gap takes the chain down even when every individual frame is genuinely decodable.
    func testSkippingAFixtureFrameAsksForAKeyframeInsteadOfShowingTheGap() async throws {
        try XCTSkipUnless(H264Fixture.isAvailable, H264Fixture.unavailableReason)
        let frames = H264Fixture.frames
        try XCTSkipUnless(frames.count >= 3, "the fixture needs a frame to skip past")
        let first = try XCTUnwrap(frames.first)
        let stream = DisplayStream(info: info(width: first.width, height: first.height))

        stream.accept(video: first)
        await wait(for: "the decoded keyframe") { stream.image != nil }
        _ = try XCTUnwrap(stream.receivedAt)

        var requests = 0
        stream.onKeyframeNeeded = { requests += 1 }
        stream.accept(video: frames[2])

        XCTAssertGreaterThan(requests, 0)
        XCTAssertTrue(stream.needsKeyframe)
        XCTAssertNil(stream.receivedAt, "a gap immediately revokes freshness")
        XCTAssertFalse(stream.isFresh())
        let recovery = try XCTUnwrap(frames.last)
        stream.accept(video: recovery)
        await wait(for: "the recovery keyframe") { stream.isFresh() }
        XCTAssertFalse(stream.needsKeyframe)
    }
}

// The barrier pauses synchronous native work, which task cancellation cannot interrupt.
// Repeated epoch changes must retain this one worker rather than creating replacement tasks.
private final class NativeWorkGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let blockedKind: String
    private var events: [String] = []
    init(_ kind: String) { blockedKind = kind }
    func enter(_ kind: String) {
        lock.lock()
        events.append(kind)
        let shouldBlock = kind == blockedKind && events.filter { $0 == kind }.count == 1
        lock.unlock()
        if shouldBlock { semaphore.wait() }
    }
    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
    func release() { semaphore.signal() }
}

@MainActor
final class BoundedDisplayWorkerTests: XCTestCase {
    func testResetStormCannotReplaceBlockedJPEGWorkerOrPublishItsObsoleteImage() async throws {
        let gate = NativeWorkGate("jpeg")
        defer { gate.release() }
        let stream = DisplayStream(info: DeskFixtures.display, beforeNativeWork: { @Sendable kind in gate.enter(kind) })
        let jpeg = try XCTUnwrap(DeskFixtures.jpeg())
        stream.accept(jpeg: jpeg)
        try await Loopback.waitUntil { gate.snapshot == ["jpeg"] }
        for _ in 0..<100 {
            stream.clear()
            stream.accept(jpeg: jpeg)
        }
        stream.clear()
        try await Loopback.pause(0.1)
        XCTAssertEqual(gate.snapshot, ["jpeg"])
        gate.release()
        try await Loopback.pause(0.2)
        XCTAssertNil(stream.image)
        XCTAssertNil(stream.receivedAt)
        stream.accept(jpeg: jpeg)
        try await Loopback.waitUntil { stream.image != nil }
        XCTAssertEqual(gate.snapshot, ["jpeg", "jpeg"])
    }

    func testAlternatingSourcesRemainBoundedBehindBlockedVideo() async throws {
        let gate = NativeWorkGate("video")
        defer { gate.release() }
        let stream = DisplayStream(info: DeskFixtures.display, beforeNativeWork: { @Sendable kind in gate.enter(kind) })
        let jpeg = try XCTUnwrap(DeskFixtures.jpeg())
        let first = try XCTUnwrap(H264Fixture.frames.first)
        stream.accept(video: first)
        try await Loopback.waitUntil { gate.snapshot == ["video"] }
        for _ in 0..<100 {
            stream.clear()
            stream.accept(jpeg: jpeg)
            stream.accept(video: first)
        }
        stream.accept(jpeg: jpeg)
        try await Loopback.pause(0.1)
        XCTAssertEqual(gate.snapshot, ["video"])
        XCTAssertNil(stream.image)
        gate.release()
        try await Loopback.waitUntil { stream.image != nil }
        XCTAssertEqual(gate.snapshot, ["video", "retire", "jpeg"])
        XCTAssertEqual(stream.image?.size.width, 32)
        XCTAssertFalse(stream.usesVideo)
    }

    func testRetirementMustFinishBeforeAnyReplacementNativeWork() async throws {
        let gate = NativeWorkGate("retire")
        defer { gate.release() }
        let stream = DisplayStream(info: DeskFixtures.display, beforeNativeWork: { @Sendable kind in gate.enter(kind) })
        let first = try XCTUnwrap(H264Fixture.frames.first)
        let jpeg = try XCTUnwrap(DeskFixtures.jpeg())
        stream.accept(video: first)
        try await Loopback.waitUntil { stream.image != nil }
        stream.clear()
        try await Loopback.waitUntil { gate.snapshot == ["video", "retire"] }
        for _ in 0..<100 {
            stream.clear()
            stream.accept(video: first)
            stream.accept(jpeg: jpeg)
        }
        try await Loopback.pause(0.1)
        XCTAssertEqual(gate.snapshot, ["video", "retire"])
        gate.release()
        try await Loopback.waitUntil { stream.image != nil }
        XCTAssertEqual(gate.snapshot, ["video", "retire", "jpeg"])
    }
}

extension H264DecoderTests {
    func testOversizedCodedSurfaceCannotHideBehindSmallCropOrEnvelope() throws {
        var allocations = 0
        let decoder = H264Decoder(beforeSessionCreation: { allocations += 1 })
        defer { decoder.invalidate() }
        var frame = try XCTUnwrap(H264Fixture.frames.first)
        // Baseline SPS: 8192x8192 coded surface, cropped down to 64x64. Both the
        // envelope and visible crop fit; the native allocation would not.
        frame.sps = try XCTUnwrap(Data(base64Encoded: "Z0IAM/QAQAAIA8AH8MAH8KA="))
        XCTAssertTrue(frame.isValid)
        XCTAssertNil(decoder.decode(frame))
        XCTAssertEqual(allocations, 0)
    }

    func testSPSMismatchRejectedBeforeSessionCreation() throws {
        var allocations = 0
        let decoder = H264Decoder(beforeSessionCreation: { allocations += 1 })
        defer { decoder.invalidate() }
        var frame = try XCTUnwrap(H264Fixture.frames.first)
        frame.width = 32
        frame.height = 32
        XCTAssertTrue(frame.isValid)
        XCTAssertNil(decoder.decode(frame))
        XCTAssertEqual(allocations, 0)
    }

    func testPredictedMetadataCannotChangeEstablishedDecoderGeometry() throws {
        let decoder = H264Decoder()
        defer { decoder.invalidate() }
        XCTAssertNotNil(decoder.decode(try XCTUnwrap(H264Fixture.frames.first)))
        var predicted = H264Fixture.frames[1]
        predicted.width = 32
        XCTAssertNil(decoder.decode(predicted))
    }

    func testInlineParameterSetCannotReachNativeSessionCreation() throws {
        var allocations = 0
        let decoder = H264Decoder(beforeSessionCreation: { allocations += 1 })
        defer { decoder.invalidate() }
        var frame = try XCTUnwrap(H264Fixture.frames.first)
        frame.payload.append(SyntheticUnit.avcc([try XCTUnwrap(frame.sps)]))
        XCTAssertFalse(frame.isValid)
        XCTAssertNil(decoder.decode(frame))
        XCTAssertEqual(allocations, 0)
    }
}

private final class AllNativeWorkGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entries = 0
    private var expiredWaits = 0
    private var firstEntryAction: (@MainActor @Sendable () -> Void)?
    func onFirstEntry(_ action: @escaping @MainActor @Sendable () -> Void) {
        lock.lock(); firstEntryAction = action; lock.unlock()
    }
    func discardFirstEntryAction() {
        lock.lock(); firstEntryAction = nil; lock.unlock()
    }
    func enter(_ kind: String) {
        lock.lock()
        entries += 1
        let action = entries == 1 ? firstEntryAction : nil
        if entries == 1 { firstEntryAction = nil }
        lock.unlock()
        // A plain main-queue callback can release native work without first resuming
        // a Swift async task on the cooperative pool that the gate may have occupied.
        if let action { DispatchQueue.main.async { action() } }
        // A failing test must never strand a cooperative executor thread indefinitely.
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            lock.lock(); expiredWaits += 1; lock.unlock()
        }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries }
    var timeoutCount: Int { lock.lock(); defer { lock.unlock() }; return expiredWaits }
    func release(_ count: Int) { for _ in 0..<count { semaphore.signal() } }
}

extension BoundedDisplayWorkerTests {
    func testNewDisplayIDsCannotCreateNativeWorkersOrWaitersBeyondProcessCap() async throws {
        let gate = AllNativeWorkGate()
        defer {
            gate.release(200)
            XCTAssertEqual(gate.timeoutCount, 0, "Native gates must be released by the test, not their fail-safe.")
        }
        let jpeg = try XCTUnwrap(DeskFixtures.jpeg())
        var originals: [DisplayStream] = []
        for id in 1...DisplayStream.maximumNativeWorkers {
            var info = DeskFixtures.display
            info.id = UInt32(id)
            let stream = DisplayStream(info: info, beforeNativeWork: { @Sendable kind in gate.enter(kind) })
            originals.append(stream)
            stream.accept(jpeg: jpeg)
        }
        // Admission reserves all four leases synchronously on the main actor. Submit every
        // replacement before yielding, so no original can finish and return capacity first.
        // Keep the originals alive while their work drains: a small cooperative pool need
        // not execute all four detached tasks simultaneously for all four to be admitted.
        var streams: [DisplayStream] = []
        for id in 10..<110 {
            var info = DeskFixtures.display
            info.id = UInt32(id)
            let replacement = DisplayStream(info: info, beforeNativeWork: { @Sendable kind in gate.enter(kind) })
            streams.append(replacement)
            replacement.accept(jpeg: jpeg)
        }
        // Release before the first suspension. All four leases are already reserved;
        // proving admission does not require four simultaneously executing native calls.
        gate.release(DisplayStream.maximumNativeWorkers)
        try await Loopback.waitUntil { originals.allSatisfy { $0.image != nil } }
        try await Loopback.pause(0.2)
        // If saturated callers queued suspended or detached waiters, releasing the old
        // workers would start them now. Dropped work must stay dropped instead.
        XCTAssertEqual(gate.count, DisplayStream.maximumNativeWorkers)
        XCTAssertTrue(streams.allSatisfy { $0.image == nil })
        let survivor = try XCTUnwrap(streams.last)
        gate.release(1)
        survivor.accept(jpeg: jpeg)
        try await Loopback.waitUntil { survivor.image != nil }
        XCTAssertEqual(gate.count, DisplayStream.maximumNativeWorkers + 1)
    }

    func testRemovedDisplayRetainsItsBlockedWorkerUntilNativeWorkFinishes() async throws {
        let gate = AllNativeWorkGate()
        defer {
            gate.discardFirstEntryAction()
            gate.release(200)
            XCTAssertEqual(gate.timeoutCount, 0, "Native gates must be released by the test, not their fail-safe.")
        }
        let jpeg = try XCTUnwrap(DeskFixtures.jpeg())
        var original: DisplayStream? = DisplayStream(
            info: DeskFixtures.display, beforeNativeWork: { @Sendable kind in gate.enter(kind) }
        )
        weak var removed = original
        var fillers: [DisplayStream] = []
        var replacements: [DisplayStream] = []
        var stagedRemoval = false
        gate.onFirstEntry {
            // Release even if an assertion fails. No async suspension is allowed between
            // the confirmed blocked native entry and releasing the admitted work.
            defer { gate.release(DisplayStream.maximumNativeWorkers) }
            XCTAssertEqual(gate.count, 1)
            // Reserve every other lease before clearing the blocked original. Fillers
            // need not have started: admission, not executor width, sets the budget.
            for id in 2...DisplayStream.maximumNativeWorkers {
                var info = DeskFixtures.display
                info.id = UInt32(id)
                let filler = DisplayStream(info: info, beforeNativeWork: { @Sendable kind in gate.enter(kind) })
                fillers.append(filler)
                filler.accept(jpeg: jpeg)
            }
            original?.clear()
            original = nil
            // The model removed this display, but its in-flight native call must still
            // own the stream and its lease. An early lease release admits a replacement.
            XCTAssertNotNil(removed)
            XCTAssertNil(removed?.image)
            for id in 10..<110 {
                var info = DeskFixtures.display
                info.id = UInt32(id)
                let replacement = DisplayStream(info: info, beforeNativeWork: { @Sendable kind in gate.enter(kind) })
                replacements.append(replacement)
                replacement.accept(jpeg: jpeg)
            }
            stagedRemoval = true
        }
        original?.accept(jpeg: jpeg)
        try await Loopback.waitUntil {
            stagedRemoval && removed == nil && fillers.allSatisfy { $0.image != nil }
        }
        try await Loopback.pause(0.2)
        XCTAssertEqual(gate.count, DisplayStream.maximumNativeWorkers)
        XCTAssertTrue(replacements.allSatisfy { $0.image == nil })

        let replacement = try XCTUnwrap(replacements.last)
        gate.release(1)
        replacement.accept(jpeg: jpeg)
        try await Loopback.waitUntil { replacement.image != nil }
        XCTAssertEqual(gate.count, DisplayStream.maximumNativeWorkers + 1)
    }
}
