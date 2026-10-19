import AppKit
import Combine
import CoreImage
import DeskCore
import DeskTransport
import Foundation

/// Main-thread and encoder work the companion spends on its own UI and on images nobody is
/// watching. Synthetic images only: no screen is captured and no window is shown.
@MainActor
func runHostEfficiencyChecks(_ runner: CheckRunner) async {
    let ids: [UInt32] = [1, 2, 3, 4]
    let inventory = ids.map { syntheticDisplay($0) }

    await runner.check("Image bursts redraw the companion at most once per watchdog tick") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned }, inventory: { inventory })
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        // One second of image fallback on four displays: twelve images each.
        for frame in 0..<12 {
            for id in ids { model.deliverImage(syntheticJPEG(width: 16 + frame * 4 + Int(id)), displayID: id) }
        }
        runner.expectEqual(publications, 0, "48 images must not redraw the companion 48 times")
        try? await Task.sleep(nanoseconds: 350_000_000)
        runner.expect((1...2).contains(publications), "one refresh per tick carries every display, got \(publications)")
        runner.expectEqual(Set(model.previews.keys), Set(ids), "every display has a thumbnail")
        for id in ids {
            runner.expectEqual(model.previews[id].map { Int($0.size.width) }, 16 + 11 * 4 + Int(id), "display \(id) shows its newest image")
        }
        model.stop()
    }

    await runner.check("An idle repeat still reaches the headset but never redraws an identical thumbnail") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned }, inventory: { inventory })
        var deliveries = 0
        let delivered = model.imageDelivered.sink { _ in deliveries += 1 }
        defer { delivered.cancel() }
        let image = syntheticJPEG(width: 24)
        model.deliverImage(image, displayID: 1)
        try? await Task.sleep(nanoseconds: 350_000_000)
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        for _ in 0..<5 { model.deliverImage(image, displayID: 1) }
        try? await Task.sleep(nanoseconds: 350_000_000)
        runner.expectEqual(publications, 0, "the same image is not decoded and redrawn again")
        runner.expectEqual(deliveries, 6, "every delivery, repeats included, still proves capture is alive")
        let channel = DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: 1), key: PairingKey.generate())
        model.attach(channel)
        let dropped = model.framesDropped
        model.deliverImage(image, displayID: 1)
        runner.expectEqual(model.framesDropped, dropped + 1, "a headset watching images is still sent the repeat (an unstarted channel refuses it)")
        model.stop()
    }

    await runner.check("Encoded-frame accounting never redraws the companion") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned }, inventory: { inventory })
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        let frames = (0..<30).flatMap { sequence in ids.map { ($0, syntheticVideoFrame(UInt64(sequence), keyframe: sequence == 0)) } }
        model.deliverVideo(frames, losses: [])
        runner.expectEqual(model.encodedFrameCounts.values.reduce(0, +), 120, "every encoded frame is counted at once")
        runner.expectEqual(model.encodedByteCount, frames.reduce(0) { $0 + $1.1.payload.count }, "bytes are counted at once")
        try? await Task.sleep(nanoseconds: 350_000_000)
        runner.expectEqual(publications, 0, "no view shows these counters, so one second of four streams redraws nothing")
        runner.expect(!model.sendingH264, "with no capture and no headset nothing is promoted to video")
        model.stop()
    }

    await runner.check("With no headset attached, images are paced as a preview rather than as the headset's picture") {
        let preview = DisplayCapture.previewOnlyInterval
        let live = 1.0 / Double(DisplayCapture.legacyFrameRate)
        runner.expectEqual(DisplayCapture.previewInterval(isDeliveringVideo: false, isHeadsetAttached: false, isVideoCapture: true), preview, "idle video capture")
        runner.expectEqual(DisplayCapture.previewInterval(isDeliveringVideo: true, isHeadsetAttached: false, isVideoCapture: true), preview, "idle, video flag stale")
        runner.expectEqual(DisplayCapture.previewInterval(isDeliveringVideo: false, isHeadsetAttached: false, isVideoCapture: false), preview, "idle legacy capture")
        let idleEncodesPerSecond = Double(DeskMessage.maximumSharedDisplays) / preview
        let previousIdleEncodesPerSecond = Double(DeskMessage.maximumSharedDisplays) / live
        runner.expect(idleEncodesPerSecond <= 8, "four idle displays encode at most 8 JPEGs a second")
        print("      idle JPEG budget, four displays: \(Int(idleEncodesPerSecond))/s (was \(Int(previousIdleEncodesPerSecond))/s)")

        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { PairingKey.generate() },
                                   contentProvider: { throw CheckError.preparationAbandoned }, inventory: { inventory },
                                   keepAwake: KeepAwakeRecorder().hold)
        runner.expect(!model.isHeadsetAttached, "a fresh host has no headset")
        runner.expectEqual(model.imageInterval, preview, "idle: preview cadence")
        let channel = DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: 1), key: PairingKey.generate())
        model.attach(channel)
        runner.expectEqual(model.imageInterval, live, "an attached headset waiting for video watches images at the legacy rate")
        model.receive(DeskMessage(kind: "capabilities", videoCodec: DeskMessage.supportedVideoCodec))
        runner.expectEqual(model.imageInterval, live, "no capture can carry video yet, so the images stay live")
        channel.cancel()
        runner.expect(!model.isHeadsetAttached, "a remote disconnect detaches the headset but keeps the host")
        runner.expectEqual(model.imageInterval, preview, "and returns the images to preview cadence")
        model.stop()
    }

    await runner.check("Refreshing an unchanged inventory publishes nothing") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned }, inventory: { inventory })
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        for _ in 0..<10 { model.refreshInventory() }
        runner.expectEqual(publications, 0, "the setup panel's two-second recheck must not redraw an unchanged companion")
        model.stop()
    }

    await runner.check("The production JPEG encoder handles a synthetic full-width frame (cost measured)") {
        guard let buffer = syntheticPixelBuffer(width: DisplayCapture.maximumWidth, height: 1_080) else {
            runner.expect(false, "a synthetic pixel buffer is required"); return
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        var samples: [Double] = []
        var size = 0
        for _ in 0..<12 {
            let started = ProcessInfo.processInfo.systemUptime
            guard let jpeg = DisplayCapture.encodeJPEG(buffer, context: context) else {
                runner.expect(false, "the encoder must produce a JPEG"); return
            }
            samples.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            size = jpeg.count
        }
        runner.expect(size > 0 && size <= DeskMessage.maximumJPEGBytes, "the JPEG fits the wire bound, got \(size) bytes")
        let cost = median(samples)
        print("      synthetic 1920x1080 JPEG encode: median \(milliseconds(cost)) ms, \(size) bytes")
        print("      idle four-display encode time: \(milliseconds(cost * 48)) ms/s at 48/s, \(milliseconds(cost * 8)) ms/s at 8/s")
    }

    await runner.check("Drawing a thumbnail decodes the full image on the calling thread (cost measured)") {
        guard let buffer = syntheticPixelBuffer(width: DisplayCapture.maximumWidth, height: 1_080),
              let jpeg = DisplayCapture.encodeJPEG(buffer, context: CIContext(options: [.cacheIntermediates: false])),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 276, pixelsHigh: 155, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            runner.expect(false, "synthetic thumbnail fixtures are required"); return
        }
        var samples: [Double] = []
        for _ in 0..<12 {
            let started = ProcessInfo.processInfo.systemUptime
            guard let image = NSImage(data: jpeg) else { runner.expect(false, "the JPEG must decode"); return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            image.draw(in: NSRect(x: 0, y: 0, width: 276, height: 155))
            NSGraphicsContext.restoreGraphicsState()
            samples.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        }
        let cost = median(samples)
        runner.expect(cost > 0, "decoding and drawing takes measurable time")
        print("      one 1920x1080 thumbnail decode+draw: median \(milliseconds(cost)) ms")
        print("      main-thread thumbnail time: \(milliseconds(cost * 48)) ms/s at 48 refreshes/s, at most \(milliseconds(cost * 16)) ms/s now (4 ticks x 4 displays)")
    }
}
