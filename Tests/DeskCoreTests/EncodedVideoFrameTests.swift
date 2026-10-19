import XCTest
@testable import DeskCore

/// Wire-validation and admission-policy tests for the H.264 path.
///
/// Nothing here decodes. `EncodedVideoFrame.isValid` is a parser over untrusted bytes and
/// `VideoStreamSequencer` is a state machine over wire metadata, so both are exercised with
/// AVCC buffers assembled byte by byte. That is the input these two types actually see, and
/// building the buffers here is what lets a test state a malformed shape precisely.
final class EncodedVideoFrameTests: XCTestCase {

    // MARK: AVCC construction

    /// One NAL unit: a header byte carrying `type` in its low five bits, then filler.
    private func nalUnit(type: UInt8, byteCount: Int = 8) -> Data {
        precondition(byteCount >= 1)
        return Data([type & 0x1F]) + Data(repeating: 0xA5, count: byteCount - 1)
    }

    /// Packs NAL units into AVCC: a four-byte big-endian length before each unit.
    private func avcc(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { buffer, unit in
            let length = UInt32(unit.count)
            buffer.append(contentsOf: [
                UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)
            ])
            buffer.append(unit)
        }
    }

    private var idrPayload: Data { avcc([nalUnit(type: EncodedVideoFrame.nalTypeIDRSlice)]) }
    private var predictedPayload: Data { avcc([nalUnit(type: EncodedVideoFrame.nalTypeNonIDRSlice)]) }
    private var sps: Data { nalUnit(type: EncodedVideoFrame.nalTypeSequenceParameterSet, byteCount: 12) }
    private var pps: Data { nalUnit(type: EncodedVideoFrame.nalTypePictureParameterSet, byteCount: 5) }

    private func keyframe(
        sequence: UInt64 = 0, width: Int = 64, height: Int = 64,
        payload: Data? = nil, sps overrideSPS: Data? = nil, pps overridePPS: Data? = nil
    ) -> EncodedVideoFrame {
        EncodedVideoFrame(
            width: width, height: height, sequence: sequence, isKeyframe: true,
            payload: payload ?? idrPayload, sps: overrideSPS ?? sps, pps: overridePPS ?? pps
        )
    }

    private func predicted(
        sequence: UInt64, width: Int = 64, height: Int = 64, payload: Data? = nil
    ) -> EncodedVideoFrame {
        EncodedVideoFrame(
            width: width, height: height, sequence: sequence, isKeyframe: false,
            payload: payload ?? predictedPayload
        )
    }

    // MARK: Well-formed frames

    func testKeyframeCarryingIDRAndBothParameterSetsIsValid() {
        XCTAssertTrue(keyframe().isValid)
    }

    func testPredictedFrameCarryingNonIDRSliceIsValid() {
        XCTAssertTrue(predicted(sequence: 1).isValid)
    }

    func testPayloadWithSeveralNALUnitsIsWalkedToTheEnd() {
        let payload = avcc([
            nalUnit(type: EncodedVideoFrame.nalTypeIDRSlice),
            nalUnit(type: 6, byteCount: 3),
            nalUnit(type: EncodedVideoFrame.nalTypeIDRSlice, byteCount: 40)
        ])
        XCTAssertEqual(EncodedVideoFrame.nalUnitTypes(in: payload), [5, 6, 5])
        XCTAssertTrue(keyframe(payload: payload).isValid)
    }

    func testCodableRoundTripPreservesEveryField() throws {
        let original = keyframe(sequence: 9, width: 128, height: 96)
        let restored = try JSONDecoder().decode(
            EncodedVideoFrame.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored, original)
        XCTAssertTrue(restored.isValid)
    }

    // MARK: Keyframe and parameter-set rules

    func testKeyframeWithoutSPSIsRejected() {
        var frame = keyframe()
        frame.sps = nil
        XCTAssertFalse(frame.isValid)
    }

    func testKeyframeWithoutPPSIsRejected() {
        var frame = keyframe()
        frame.pps = nil
        XCTAssertFalse(frame.isValid)
    }

    /// A sender must not pass off a predicted picture as a resynchronization point.
    func testKeyframeWhosePayloadHasNoIDRSliceIsRejected() {
        XCTAssertFalse(keyframe(payload: predictedPayload).isValid)
    }

    func testParameterSetsHoldingTheWrongNALTypeAreRejected() {
        XCTAssertFalse(keyframe(sps: pps).isValid, "a PPS in the SPS slot must not pass")
        XCTAssertFalse(keyframe(pps: sps).isValid, "an SPS in the PPS slot must not pass")
    }

    func testParameterSetShorterThanTwoBytesIsRejected() {
        let single = Data([EncodedVideoFrame.nalTypeSequenceParameterSet])
        XCTAssertFalse(keyframe(sps: single).isValid)
    }

    func testParameterSetOverTheSizeCapIsRejected() {
        let oversized = nalUnit(
            type: EncodedVideoFrame.nalTypeSequenceParameterSet,
            byteCount: EncodedVideoFrame.maximumParameterSetBytes + 1
        )
        XCTAssertFalse(keyframe(sps: oversized).isValid)
    }

    func testParameterSetWithForbiddenZeroBitSetIsRejected() {
        var corrupted = sps
        corrupted[corrupted.startIndex] |= 0x80
        XCTAssertFalse(keyframe(sps: corrupted).isValid)
    }

    // MARK: Predicted-frame rules

    /// Accepting an IDR inside a predicted frame would let a sender smuggle in a keyframe that
    /// the sequencer never recorded as one.
    func testPredictedFrameCarryingAnIDRIsRejected() {
        XCTAssertFalse(predicted(sequence: 1, payload: idrPayload).isValid)
    }

    func testPredictedFrameCarryingParameterSetsIsRejected() {
        var withSPS = predicted(sequence: 1)
        withSPS.sps = sps
        XCTAssertFalse(withSPS.isValid)

        var withPPS = predicted(sequence: 1)
        withPPS.pps = pps
        XCTAssertFalse(withPPS.isValid)
    }

    func testPredictedFrameWithoutAnySliceIsRejected() {
        XCTAssertFalse(predicted(sequence: 1, payload: avcc([nalUnit(type: 6)])).isValid)
    }

    // MARK: Geometry and sequence bounds

    func testOddDimensionsAreRejected() {
        XCTAssertFalse(keyframe(width: 65).isValid)
        XCTAssertFalse(keyframe(height: 65).isValid)
    }

    func testDimensionsOutsideTheSupportedRangeAreRejected() {
        XCTAssertFalse(keyframe(width: EncodedVideoFrame.minimumDimension - 2).isValid)
        XCTAssertFalse(keyframe(height: EncodedVideoFrame.minimumDimension - 2).isValid)
        XCTAssertFalse(keyframe(width: EncodedVideoFrame.maximumDimension + 2).isValid)
        XCTAssertFalse(keyframe(height: EncodedVideoFrame.maximumDimension + 2).isValid)
    }

    func testDimensionsAtTheSupportedBoundsAreAccepted() {
        let minimum = EncodedVideoFrame.minimumDimension
        XCTAssertTrue(keyframe(width: minimum, height: minimum).isValid)
    }

    /// Each edge is in range on its own, but the product is over the decoded-bitmap budget.
    func testPixelBudgetIsEnforcedAcrossBothEdges() {
        XCTAssertGreaterThan(4_096 * 2_078, EncodedVideoFrame.maximumPixels)
        XCTAssertFalse(keyframe(width: 4_096, height: 2_078).isValid)
        XCTAssertTrue(keyframe(width: 4_096, height: 2_074).isValid)
    }

    func testSequenceBeyondTheExactlyRepresentableRangeIsRejected() {
        XCTAssertTrue(keyframe(sequence: EncodedVideoFrame.maximumSequence).isValid)
        XCTAssertFalse(keyframe(sequence: EncodedVideoFrame.maximumSequence + 1).isValid)
    }

    // MARK: Malformed payloads

    func testEmptyPayloadIsRejected() {
        XCTAssertFalse(keyframe(payload: Data()).isValid)
        XCTAssertNil(EncodedVideoFrame.nalUnitTypes(in: Data()))
    }

    func testPayloadOverTheSizeCapIsRejected() {
        let oversized = Data(repeating: 0, count: EncodedVideoFrame.maximumPayloadBytes + 1)
        XCTAssertFalse(keyframe(payload: oversized).isValid)
    }

    /// A length prefix with no NAL unit behind it is not a zero-unit payload, it is truncation.
    func testLengthPrefixWithNoUnitBehindItIsRejected() {
        XCTAssertNil(EncodedVideoFrame.nalUnitTypes(in: Data([0, 0, 0, 1])))
        XCTAssertFalse(keyframe(payload: Data([0, 0, 0, 1])).isValid)
    }

    func testPayloadShorterThanALengthPrefixIsRejected() {
        XCTAssertNil(EncodedVideoFrame.nalUnitTypes(in: Data([0, 0, 1])))
    }

    func testLengthPrefixOverrunningTheBufferIsRejected() {
        var payload = avcc([nalUnit(type: EncodedVideoFrame.nalTypeIDRSlice)])
        payload[payload.startIndex + 3] = 0xFF
        XCTAssertNil(EncodedVideoFrame.nalUnitTypes(in: payload))
        XCTAssertFalse(keyframe(payload: payload).isValid)
    }

    func testZeroLengthNALUnitIsRejected() {
        XCTAssertNil(EncodedVideoFrame.nalUnitTypes(in: Data([0, 0, 0, 0, 0x65])))
    }

    /// Bytes after the final unit are not ignored: the walk must consume the buffer exactly.
    func testTrailingBytesAfterTheFinalUnitAreRejected() {
        let payload = idrPayload + Data([0x00, 0x00])
        XCTAssertNil(EncodedVideoFrame.nalUnitTypes(in: payload))
        XCTAssertFalse(keyframe(payload: payload).isValid)
    }

    func testNALUnitWithForbiddenZeroBitSetIsRejected() {
        var payload = idrPayload
        payload[payload.startIndex + EncodedVideoFrame.lengthPrefixBytes] |= 0x80
        XCTAssertNil(EncodedVideoFrame.nalUnitTypes(in: payload))
    }

    func testReservedAndPacketizationNALTypesAreRejected() {
        for type: UInt8 in [0, 24, 31] {
            let payload = avcc([Data([type]) + Data(repeating: 0, count: 4)])
            XCTAssertNil(
                EncodedVideoFrame.nalUnitTypes(in: payload),
                "NAL type \(type) must not be accepted"
            )
        }
    }

    /// Validation itself must not become the denial of service.
    func testPayloadOverTheNALUnitCountCapIsRejected() {
        let one = nalUnit(type: EncodedVideoFrame.nalTypeNonIDRSlice, byteCount: 1)
        let atCap = avcc(Array(repeating: one, count: EncodedVideoFrame.maximumNALUnitCount))
        let overCap = avcc(Array(repeating: one, count: EncodedVideoFrame.maximumNALUnitCount + 1))
        XCTAssertEqual(
            EncodedVideoFrame.nalUnitTypes(in: atCap)?.count,
            EncodedVideoFrame.maximumNALUnitCount
        )
        XCTAssertNil(EncodedVideoFrame.nalUnitTypes(in: overCap))
    }
}

/// Admission policy, exercised as a state machine: every case is reached by driving the
/// sequencer through a frame order a real stream can actually produce.
final class VideoStreamSequencerTests: XCTestCase {

    private func nalUnit(type: UInt8, byteCount: Int = 8) -> Data {
        Data([type & 0x1F]) + Data(repeating: 0xA5, count: byteCount - 1)
    }

    private func avcc(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { buffer, unit in
            let length = UInt32(unit.count)
            buffer.append(contentsOf: [
                UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)
            ])
            buffer.append(unit)
        }
    }

    private func keyframe(_ sequence: UInt64, width: Int = 64, height: Int = 64) -> EncodedVideoFrame {
        EncodedVideoFrame(
            width: width, height: height, sequence: sequence, isKeyframe: true,
            payload: avcc([nalUnit(type: EncodedVideoFrame.nalTypeIDRSlice)]),
            sps: nalUnit(type: EncodedVideoFrame.nalTypeSequenceParameterSet, byteCount: 12),
            pps: nalUnit(type: EncodedVideoFrame.nalTypePictureParameterSet, byteCount: 5)
        )
    }

    private func predicted(_ sequence: UInt64, width: Int = 64, height: Int = 64) -> EncodedVideoFrame {
        EncodedVideoFrame(
            width: width, height: height, sequence: sequence, isKeyframe: false,
            payload: avcc([nalUnit(type: EncodedVideoFrame.nalTypeNonIDRSlice)])
        )
    }

    private var malformed: EncodedVideoFrame {
        EncodedVideoFrame(width: 64, height: 64, sequence: 1, isKeyframe: false, payload: Data())
    }

    // MARK: Startup

    func testSequencerStartsAwaitingAKeyframe() {
        let sequencer = VideoStreamSequencer()
        XCTAssertTrue(sequencer.isAwaitingKeyframe)
        XCTAssertNil(sequencer.lastSequence)
        XCTAssertNil(sequencer.width)
        XCTAssertNil(sequencer.height)
    }

    func testPredictedFrameBeforeAnyKeyframeIsRejected() {
        var sequencer = VideoStreamSequencer()
        XCTAssertEqual(sequencer.admit(predicted(0)), .rejectAwaitingKeyframe)
        XCTAssertNil(sequencer.lastSequence, "a rejected frame must not become the reference")
    }

    /// The first keyframe has no previous geometry to match, so it resets the pipeline.
    func testFirstKeyframeIsAdmittedAndResetsThePipeline() {
        var sequencer = VideoStreamSequencer()
        XCTAssertEqual(sequencer.admit(keyframe(0)), .decode(resetsPipeline: true))
        XCTAssertFalse(sequencer.isAwaitingKeyframe)
        XCTAssertEqual(sequencer.lastSequence, 0)
        XCTAssertEqual(sequencer.width, 64)
        XCTAssertEqual(sequencer.height, 64)
    }

    // MARK: Steady state

    func testConsecutivePredictedFramesAreAdmittedWithoutResetting() {
        var sequencer = VideoStreamSequencer()
        XCTAssertEqual(sequencer.admit(keyframe(0)), .decode(resetsPipeline: true))
        XCTAssertEqual(sequencer.admit(predicted(1)), .decode(resetsPipeline: false))
        XCTAssertEqual(sequencer.admit(predicted(2)), .decode(resetsPipeline: false))
        XCTAssertEqual(sequencer.lastSequence, 2)
    }

    func testRepeatedKeyframeAtTheSameGeometryDoesNotResetThePipeline() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(0))
        XCTAssertEqual(sequencer.admit(keyframe(1)), .decode(resetsPipeline: false))
    }

    func testKeyframeAtANewGeometryResetsThePipeline() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(0))
        XCTAssertEqual(
            sequencer.admit(keyframe(1, width: 128, height: 96)),
            .decode(resetsPipeline: true)
        )
        XCTAssertEqual(sequencer.width, 128)
        XCTAssertEqual(sequencer.height, 96)
    }

    // MARK: Gaps

    func testSkippedSequenceBreaksTheChainAndDemandsAKeyframe() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(0))
        XCTAssertEqual(sequencer.admit(predicted(2)), .rejectGap)
        XCTAssertTrue(sequencer.isAwaitingKeyframe)
        XCTAssertEqual(sequencer.lastSequence, 0, "a gap must not advance the reference")
    }

    func testFramesAfterAGapStayRejectedUntilAKeyframeArrives() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(0))
        XCTAssertEqual(sequencer.admit(predicted(2)), .rejectGap)
        // Sequence 1 never arrives, so even the next in-order frame has no reference chain.
        XCTAssertEqual(sequencer.admit(predicted(3)), .rejectAwaitingKeyframe)
        XCTAssertEqual(sequencer.admit(predicted(4)), .rejectAwaitingKeyframe)
    }

    func testKeyframeRecoversTheStreamAfterAGap() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(0))
        XCTAssertEqual(sequencer.admit(predicted(5)), .rejectGap)
        XCTAssertEqual(sequencer.admit(keyframe(6)), .decode(resetsPipeline: false))
        XCTAssertFalse(sequencer.isAwaitingKeyframe)
        XCTAssertEqual(sequencer.admit(predicted(7)), .decode(resetsPipeline: false))
    }

    /// Same sequence, different screen size: the bytes cannot describe the recorded geometry.
    func testPredictedFrameWithMismatchedGeometryIsTreatedAsAGap() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(0))
        XCTAssertEqual(sequencer.admit(predicted(1, width: 128)), .rejectGap)
        XCTAssertTrue(sequencer.isAwaitingKeyframe)

        var byHeight = VideoStreamSequencer()
        _ = byHeight.admit(keyframe(0))
        XCTAssertEqual(byHeight.admit(predicted(1, height: 96)), .rejectGap)
        XCTAssertTrue(byHeight.isAwaitingKeyframe)
    }

    // MARK: Stale frames

    func testDuplicateSequenceIsRejectedAsStale() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(0))
        _ = sequencer.admit(predicted(1))
        XCTAssertEqual(sequencer.admit(predicted(1)), .rejectStale)
        XCTAssertEqual(sequencer.lastSequence, 1)
        XCTAssertFalse(sequencer.isAwaitingKeyframe, "a stale frame must not break the chain")
    }

    func testOutOfOrderFrameIsRejectedAsStale() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(0))
        _ = sequencer.admit(predicted(1))
        _ = sequencer.admit(predicted(2))
        XCTAssertEqual(sequencer.admit(predicted(1)), .rejectStale)
        XCTAssertEqual(sequencer.lastSequence, 2)
    }

    /// A late duplicate keyframe would otherwise rewind the screen to an older picture.
    func testLateKeyframeDoesNotRewindTheStream() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(4))
        _ = sequencer.admit(predicted(5))
        XCTAssertEqual(sequencer.admit(keyframe(4)), .rejectStale)
        XCTAssertEqual(sequencer.admit(keyframe(2)), .rejectStale)
        XCTAssertEqual(sequencer.lastSequence, 5)
    }

    /// A sender whose counter restarts below the recorded reference is refused, and stays
    /// refused however many times it insists.
    ///
    /// This is the rule working, not a defect in it. The comparison is the anti-replay
    /// protection: an exception for keyframes would let any sender put an older screen back
    /// under a live pointer and stamp it as fresh. Recovery from a genuine restart belongs to
    /// the stream, which calls `reset()` at the discontinuity — see the test below.
    func testASenderThatRestartsItsSequenceIsRefusedRatherThanRewindingTheScreen() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(500))
        XCTAssertEqual(sequencer.admit(predicted(501)), .decode(resetsPipeline: false))
        // A restarted run, insisting with keyframes rather than one late duplicate.
        for sequence: UInt64 in [1, 2, 3, 4] {
            XCTAssertEqual(sequencer.admit(keyframe(sequence)), .rejectStale,
                           "sequence \(sequence) is behind the reference and may not be shown")
        }
        XCTAssertEqual(sequencer.lastSequence, 501, "a refused frame may not become the reference")
        XCTAssertFalse(sequencer.isAwaitingKeyframe,
                       "refusing a rewind must not break a chain that is still intact")
        // The continuing original run is unaffected, so a reordered burst costs nothing.
        XCTAssertEqual(sequencer.admit(predicted(502)), .decode(resetsPipeline: false))
    }

    /// The supported recovery, which the stream performs at any discontinuity that can
    /// renumber a sender: a reconnect, a resolution change, or a return from JPEG fallback.
    func testResetIsTheRecoveryFromARestartedSequence() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(500))
        XCTAssertEqual(sequencer.admit(keyframe(1)), .rejectStale)

        sequencer.reset()
        XCTAssertEqual(sequencer.admit(keyframe(1)), .decode(resetsPipeline: true),
                       "a stream with no reference accepts the restarted run's first keyframe")
        XCTAssertEqual(sequencer.admit(predicted(2)), .decode(resetsPipeline: false))
        XCTAssertEqual(sequencer.lastSequence, 2)
    }

    /// Staleness is judged before the keyframe wait, so a stale frame cannot clear the wait.
    func testStaleKeyframeDoesNotSatisfyAPendingKeyframeRequirement() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(3))
        sequencer.requireKeyframe()
        XCTAssertEqual(sequencer.admit(keyframe(3)), .rejectStale)
        XCTAssertTrue(sequencer.isAwaitingKeyframe)
    }

    // MARK: Malformed frames

    func testMalformedFrameIsRejectedAndDemandsAKeyframe() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(0))
        _ = sequencer.admit(predicted(1))
        XCTAssertEqual(sequencer.admit(malformed), .rejectMalformed)
        XCTAssertTrue(sequencer.isAwaitingKeyframe)
        XCTAssertEqual(sequencer.lastSequence, 1, "a malformed frame must not advance the chain")
    }

    /// Malformed is checked before staleness: a corrupt unit may still have advanced the
    /// sender's reference chain, so it has to force a resynchronization either way.
    func testMalformedFrameIsRejectedEvenWhenItsSequenceIsStale() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(8))
        var corrupt = malformed
        corrupt.sequence = 2
        XCTAssertEqual(sequencer.admit(corrupt), .rejectMalformed)
        XCTAssertTrue(sequencer.isAwaitingKeyframe)
    }

    // MARK: Explicit control

    func testRequireKeyframeBlocksPredictedFramesButNotKeyframes() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(0))
        sequencer.requireKeyframe()
        XCTAssertEqual(sequencer.admit(predicted(1)), .rejectAwaitingKeyframe)
        XCTAssertEqual(sequencer.admit(keyframe(2)), .decode(resetsPipeline: false))
        XCTAssertFalse(sequencer.isAwaitingKeyframe)
    }

    func testRequireKeyframeKeepsTheRecordedGeometryAndSequence() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(0, width: 128, height: 96))
        sequencer.requireKeyframe()
        XCTAssertEqual(sequencer.lastSequence, 0)
        XCTAssertEqual(sequencer.width, 128)
        XCTAssertEqual(sequencer.height, 96)
    }

    func testResetReturnsTheSequencerToItsInitialState() {
        var sequencer = VideoStreamSequencer()
        _ = sequencer.admit(keyframe(7, width: 128, height: 96))
        _ = sequencer.admit(predicted(8, width: 128, height: 96))
        sequencer.reset()
        XCTAssertEqual(sequencer, VideoStreamSequencer())
        XCTAssertTrue(sequencer.isAwaitingKeyframe)
        XCTAssertNil(sequencer.lastSequence)
        XCTAssertNil(sequencer.width)
        XCTAssertNil(sequencer.height)
        // A reset stream has no geometry, so its next keyframe resets the pipeline again.
        XCTAssertEqual(sequencer.admit(keyframe(9, width: 128, height: 96)), .decode(resetsPipeline: true))
    }
}
