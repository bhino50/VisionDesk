import CoreVideo
import Foundation
import ImageIO

/// The production JPEG output of a capture — pacing, the frame pacing held back, and the idle
/// repeat — driven with synthetic frames and explicit times. This is the same `PreviewPipeline`
/// every `DisplayCapture` feeds from ScreenCaptureKit, at the intervals `previewInterval` gives
/// each path that carries JPEG. No screen is captured.
@MainActor
func runPreviewPacingChecks(_ runner: CheckRunner) async {
    let noHeadset = DisplayCapture.previewInterval(isDeliveringVideo: false, isHeadsetAttached: false, isVideoCapture: true)
    let imagesForHeadset = DisplayCapture.previewInterval(isDeliveringVideo: false, isHeadsetAttached: true, isVideoCapture: true)
    let jpegOnlyIdle = DisplayCapture.previewInterval(isDeliveringVideo: false, isHeadsetAttached: false, isVideoCapture: false)
    let jpegOnlyWatched = DisplayCapture.previewInterval(isDeliveringVideo: false, isHeadsetAttached: true, isVideoCapture: false)
    let repeatInterval = DisplayCapture.idleRepeatInterval
    let justAfter = 0.01
    let start = 100.0
    let frames = Dictionary(uniqueKeysWithValues: (16...20).compactMap { width in labeledFrame(width).map { (width, $0) } })
    guard frames.count == 5, let f16 = frames[16], let f17 = frames[17], let f18 = frames[18], let f19 = frames[19], let f20 = frames[20] else {
        await runner.check("Synthetic preview frames can be built") { runner.expect(false, "CVPixelBufferCreate failed") }
        return
    }

    await runner.check("A change held back by pacing is encoded at the next idle callback instead of being lost") {
        let log = FrameLog()
        let count = EncodeCount()
        let pipeline = labeledPipeline(log: log, count: count)
        pipeline.frame(f16, at: start, interval: noHeadset)
        pipeline.frame(f17, at: start + 0.2, interval: noHeadset)  // the last change before the screen goes still
        runner.expect(pipeline.hasPendingFrame, "pacing holds the newest change back instead of dropping it")
        pipeline.idle(at: start + 0.3, interval: noHeadset)
        runner.expectEqual(labels(log), ["w16"], "inside the interval nothing new is sent yet")
        pipeline.idle(at: start + noHeadset + justAfter, interval: noHeadset)
        runner.expectEqual(labels(log), ["w16", "w17"], "the first idle callback after the interval delivers the held-back change")
        runner.expect(!pipeline.hasPendingFrame, "and lets the held frame go")
        pipeline.idle(at: start + noHeadset + 0.4, interval: noHeadset)
        pipeline.idle(at: start + noHeadset + repeatInterval + 2 * justAfter, interval: noHeadset)
        runner.expectEqual(labels(log), ["w16", "w17", "w17"], "idle repeats then carry the new picture on their usual cadence")
        runner.expectEqual(count.value, 2, "each picture is encoded once")
        runner.expectEqual(log.entries.map(\.id), [7, 7, 7], "every delivery keeps its display identifier")
    }

    await runner.check("Only the newest held-back frame is encoded, and a later change still waits for the interval") {
        let log = FrameLog()
        let count = EncodeCount()
        let pipeline = labeledPipeline(log: log, count: count)
        pipeline.frame(f16, at: start, interval: noHeadset)
        for (offset, frame) in [(0.1, f17), (0.2, f18), (0.3, f19)] { pipeline.frame(frame, at: start + offset, interval: noHeadset) }
        pipeline.idle(at: start + noHeadset + justAfter, interval: noHeadset)
        runner.expectEqual(labels(log), ["w16", "w19"], "the change that ended the motion is the one encoded")
        runner.expectEqual(count.value, 2, "superseded frames are never encoded")
        pipeline.frame(f20, at: start + noHeadset + 0.2, interval: noHeadset)
        runner.expectEqual(labels(log), ["w16", "w19"], "a change right after the flush is not sent early")
        pipeline.idle(at: start + 2 * noHeadset + 2 * justAfter, interval: noHeadset)
        runner.expectEqual(labels(log), ["w16", "w19", "w20"], "and the next idle callback after the interval delivers it")
    }

    await runner.check("A headset watching images gets the change that ended the motion, at its own cadence") {
        let log = FrameLog()
        let pipeline = labeledPipeline(log: log, count: EncodeCount())
        let captureInterval = 1.0 / Double(DisplayCapture.videoFrameRate)
        pipeline.frame(f16, at: start, interval: imagesForHeadset)
        pipeline.frame(f17, at: start + captureInterval, interval: imagesForHeadset)
        pipeline.idle(at: start + 2 * captureInterval, interval: imagesForHeadset)
        runner.expectEqual(labels(log), ["w16"], "the 30 fps capture is still inside the headset's image interval")
        pipeline.idle(at: start + 3 * captureInterval, interval: imagesForHeadset)
        runner.expectEqual(labels(log), ["w16", "w17"], "the next idle callback sends a JPEG-only headset the final picture")
    }

    await runner.check("A capture never configured for video holds back the same way; a watched one holds nothing back") {
        let log = FrameLog()
        let pipeline = labeledPipeline(log: log, count: EncodeCount())
        pipeline.frame(f16, at: start, interval: jpegOnlyIdle)
        pipeline.frame(f17, at: start + 0.2, interval: jpegOnlyIdle)
        pipeline.idle(at: start + jpegOnlyIdle + justAfter, interval: jpegOnlyIdle)
        runner.expectEqual(labels(log), ["w16", "w17"], "with no headset the last change still reaches the preview")
        let watchedLog = FrameLog()
        let watched = labeledPipeline(log: watchedLog, count: EncodeCount())
        watched.frame(f16, at: start, interval: jpegOnlyWatched)
        watched.frame(f17, at: start + justAfter, interval: jpegOnlyWatched)
        runner.expect(!watched.hasPendingFrame, "ScreenCaptureKit already paces a watched JPEG-only capture, so nothing is held")
        runner.expectEqual(labels(watchedLog), ["w16", "w17"], "every frame is sent, exactly as before")
    }

    await runner.check("A held-back frame that cannot be encoded costs one attempt, and a stop lets a held frame go") {
        let log = FrameLog()
        let count = EncodeCount()
        let pipeline = labeledPipeline(log: log, count: count, failing: [17])
        pipeline.frame(f16, at: start, interval: noHeadset)
        pipeline.frame(f17, at: start + 0.2, interval: noHeadset)
        for offset in [0.51, 0.55, 0.6, 0.7] { pipeline.idle(at: start + offset, interval: noHeadset) }
        runner.expectEqual(count.value, 2, "the unencodable frame is tried once, not on every idle callback")
        runner.expectEqual(labels(log), ["w16"], "nothing is sent for it")
        pipeline.idle(at: start + repeatInterval + justAfter, interval: noHeadset)
        runner.expectEqual(labels(log), ["w16", "w16"], "the last good picture keeps the headset's freshness window open")
        pipeline.frame(f18, at: start + repeatInterval + 0.1, interval: noHeadset)
        runner.expect(pipeline.hasPendingFrame, "a new change is held back again")
        pipeline.discardPending()
        pipeline.idle(at: start + repeatInterval + noHeadset + 2 * justAfter, interval: noHeadset)
        runner.expect(!pipeline.hasPendingFrame && count.value == 2, "a discarded frame is released and never encoded")
    }

    await runner.check("With the production encoder the held-back frame itself reaches the companion and the next attach") {
        let log = FrameLog()
        let pipeline = PreviewPipeline(id: 2, deliver: { id, jpeg in log.append(id: id, jpeg: jpeg) })
        guard let early = syntheticPixelBuffer(width: 64, height: 36), let final = syntheticPixelBuffer(width: 96, height: 54) else {
            runner.expect(false, "synthetic frames are required"); return
        }
        pipeline.frame(early, at: start, interval: noHeadset)
        pipeline.frame(final, at: start + 0.2, interval: noHeadset)
        pipeline.idle(at: start + noHeadset + justAfter, interval: noHeadset)
        runner.expectEqual(log.entries.map { jpegWidth($0.jpeg) }, [64, 96], "the JPEG sent once the screen goes still is the newest frame")
        runner.expectEqual(pipeline.latestJPEG.flatMap(jpegWidth), 96, "and it is what idle repeats and the next attach send")
    }
}

/// Counts encoder calls. Touched only by the synchronous pipeline calls inside one check.
private final class EncodeCount {
    var value = 0
}

/// A pipeline whose encoder labels each JPEG with the frame's pixel width, so every delivery
/// traces back to the exact frame that was encoded. Widths in `failing` cannot be encoded.
private func labeledPipeline(log: FrameLog, count: EncodeCount, failing: Set<Int> = []) -> PreviewPipeline {
    PreviewPipeline(id: 7, encode: { buffer in
        count.value += 1
        let width = CVPixelBufferGetWidth(buffer)
        return failing.contains(width) ? nil : Data("w\(width)".utf8)
    }, deliver: { id, jpeg in log.append(id: id, jpeg: jpeg) })
}

private func labeledFrame(_ width: Int) -> CVPixelBuffer? { syntheticPixelBuffer(width: width, height: 8) }

private func labels(_ log: FrameLog) -> [String] { log.entries.map { String(decoding: $0.jpeg, as: UTF8.self) } }

private func jpegWidth(_ jpeg: Data) -> Int? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    return properties[kCGImagePropertyPixelWidth] as? Int
}
