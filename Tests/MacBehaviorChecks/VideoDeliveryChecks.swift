import Foundation
import DeskCore

@MainActor
func runVideoDeliveryChecks(_ runner: CheckRunner) async {
    func frame(_ sequence: UInt64, keyframe: Bool) -> EncodedVideoFrame {
        EncodedVideoFrame(width: 64, height: 64, sequence: sequence, isKeyframe: keyframe,
            payload: Data([0, 0, 0, 1, keyframe ? 0x65 : 0x41]),
            sps: keyframe ? Data([0x67, 0x42]) : nil, pps: keyframe ? Data([0x68, 0xCE]) : nil)
    }
    await runner.check("Four display queues preserve ordering without starving a recovery keyframe") {
        var delivered: [(UInt32, EncodedVideoFrame)] = []
        var losses = Set<UInt32>()
        let delivery = OrderedVideoDelivery { frames, dropped in delivered += frames; losses.formUnion(dropped) }
        for id: UInt32 in 1...4 {
            delivery.submit(id: id, frame: frame(0, keyframe: true))
            delivery.submit(id: id, frame: frame(1, keyframe: false))
        }
        // An overloaded first display loses its own chain, then immediately offers
        // a recovery keyframe while the other three displays still occupy six slots.
        delivery.submit(id: 1, frame: frame(2, keyframe: false))
        delivery.submit(id: 1, frame: frame(3, keyframe: true))
        await drainMainActor()
        runner.expect(losses.contains(1), "overflow reports the affected display")
        runner.expectEqual(delivered.filter { $0.0 == 1 }.map { $0.1.sequence }, [3], "the recovery keyframe always receives a slot")
        for id: UInt32 in 2...4 {
            runner.expectEqual(delivered.filter { $0.0 == id }.map { $0.1.sequence }, [0, 1], "other display ordering is preserved")
        }
    }
    await runner.check("Unusable encoder output retries a bounded number of times, then yields video") {
        let limit = DisplayCapture.maximumConsecutiveInvalidUnits
        runner.expect(limit >= 2, "a ceiling below two would give up on the first repairable break")
        var budget = InvalidOutputBudget()
        var responses: [InvalidOutputBudget.Response] = []
        for _ in 0..<limit { responses.append(budget.recordInvalid(limit: limit)) }
        runner.expectEqual(responses.dropLast().filter { $0 != .requestKeyframe }.count, 0,
            "every failure below the ceiling asks for a keyframe")
        runner.expect(responses.last == .giveUpOnVideo, "the ceiling stops the retry loop")
        runner.expectEqual(budget.consecutive, limit, "the reported run length is the one that tripped the ceiling")
    }
    await runner.check("One usable frame clears the invalid-output run so corruption cannot accumulate") {
        let limit = DisplayCapture.maximumConsecutiveInvalidUnits
        var budget = InvalidOutputBudget()
        // Alternating failures are intermittent, not terminal: the display keeps its encoder.
        for _ in 0..<(limit * 3) {
            runner.expectEqual(budget.recordInvalid(limit: limit), .requestKeyframe, "an isolated failure is repairable")
            budget.recordValid()
        }
        runner.expectEqual(budget.consecutive, 0, "a usable unit resets the run")
    }
    await runner.check("Image cadence follows actual video delivery, not the presence of an encoder") {
        // The negotiation window: every encoder is live, but the session is still serving JPEG,
        // so that JPEG is the picture the headset sees and must not be cut to the preview rate.
        let negotiating = DisplayCapture.previewInterval(isDeliveringVideo: false, isHeadsetAttached: true, isVideoCapture:true)
        let delivering = DisplayCapture.previewInterval(isDeliveringVideo: true, isHeadsetAttached: true, isVideoCapture:true)
        runner.expect(negotiating < delivering,
            "a live encoder whose video is not being sent must not throttle the image the peer is actually watching")
        runner.expectEqual(negotiating, 1.0 / Double(DisplayCapture.legacyFrameRate),
            "an undelivered-video display runs images at the legacy rate")
    }
    await runner.check("Image fallback runs at the legacy rate, not the preview rate or the capture rate") {
        let streaming = DisplayCapture.previewInterval(isDeliveringVideo: true, isHeadsetAttached: true, isVideoCapture:true)
        let fallback = DisplayCapture.previewInterval(isDeliveringVideo: false, isHeadsetAttached: true, isVideoCapture:true)
        let legacyOnly = DisplayCapture.previewInterval(isDeliveringVideo: false, isHeadsetAttached: true, isVideoCapture:false)
        let legacyInterval = 1.0 / Double(DisplayCapture.legacyFrameRate)
        let captureInterval = 1.0 / Double(DisplayCapture.videoFrameRate)

        runner.expectEqual(streaming, DisplayCapture.previewOnlyInterval,
            "while video carries the screen the JPEG stays a background preview")
        runner.expectEqual(fallback, legacyInterval,
            "a display that lost video must not stay on the half-second preview cadence")
        runner.expect(fallback < streaming, "falling back has to be faster than previewing, not slower")
        runner.expect(fallback > captureInterval,
            "falling back must not run at the 30fps capture rate: four displays would be 120 JPEG encodes a second")
        runner.expectEqual(legacyOnly, 0,
            "a capture never configured for video is already paced by ScreenCaptureKit and keeps its exact behavior")

        // The bound that actually matters is the aggregate across every shared display.
        let worstCaseEncodesPerSecond = Double(DeskMessage.maximumSharedDisplays) / fallback
        runner.expect(worstCaseEncodesPerSecond <= Double(DeskMessage.maximumSharedDisplays * DisplayCapture.legacyFrameRate),
            "four displays in fallback stay within the legacy budget of 48 JPEG encodes a second")
    }
    await runner.check("Parameter sets are chosen by NAL type and bounds, not by index") {
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        func selected(_ candidates: [Data]) -> (Data, Data)? { H264Encoder.parameterSets(among: candidates) }

        let ordered = selected([sps, pps])
        runner.expect(ordered?.0 == sps && ordered?.1 == pps, "the ordinary order is preserved")
        let reversed = selected([pps, sps])
        runner.expect(reversed?.0 == sps && reversed?.1 == pps, "a reversed pair is still read correctly")
        // A supplemental enhancement unit ahead of the real sets is what index 0 and 1 would
        // have mistaken for SPS and PPS.
        let offset = selected([Data([0x06, 0x05]), sps, pps])
        runner.expect(offset?.0 == sps && offset?.1 == pps, "an unrelated leading unit is skipped")
        runner.expect(selected([sps]) == nil, "a missing picture parameter set is refused")
        runner.expect(selected([pps]) == nil, "a missing sequence parameter set is refused")
        runner.expect(selected([]) == nil, "an empty descriptor is refused")
        runner.expect(selected([Data([0xE7, 0x42]), pps]) == nil,
            "forbidden_zero_bit set disqualifies a candidate instead of being masked away")
        runner.expect(selected([Data([0x67]), pps]) == nil, "a one-byte set is below the wire minimum")
        let oversize = Data([0x67]) + Data(repeating: 0, count: EncodedVideoFrame.maximumParameterSetBytes)
        runner.expect(selected([oversize, pps]) == nil, "a set past the wire maximum is refused")
        let firstWins = selected([sps, Data([0x67, 0x4D]), pps])
        runner.expect(firstWins?.0 == sps, "the first usable set of each type is the one chosen")
    }
    await runner.check("A dropped predictive chain remains gated across actor drains") {
        var delivered: [EncodedVideoFrame] = []
        let delivery = OrderedVideoDelivery { frames, _ in delivered += frames.map(\.1) }
        delivery.submit(id: 1, frame: frame(0, keyframe: true))
        delivery.submit(id: 1, frame: frame(1, keyframe: false))
        delivery.submit(id: 1, frame: frame(2, keyframe: false))
        await drainMainActor()
        runner.expect(delivered.isEmpty, "overflow sheds the orphaned chain")
        delivery.submit(id: 1, frame: frame(3, keyframe: false))
        await drainMainActor()
        runner.expect(delivered.isEmpty, "a later drain cannot admit orphaned predicted frames")
        delivery.submit(id: 1, frame: frame(4, keyframe: true))
        await drainMainActor()
        runner.expectEqual(delivered.map(\.sequence), [4], "a new keyframe restores delivery")
    }
}
