import Foundation
import CoreVideo
import CoreGraphics
import DeskCore

private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

private enum CheckError: Error {
    case pixelBuffer(OSStatus)
    case bitmapContext
}

/// Immutable after construction: VideoToolbox may retain a submitted buffer after encode()
/// returns. Repainting one shared buffer while it is in flight would invalidate this test.
private final class SyntheticFrames: @unchecked Sendable {
    let buffers: [CVPixelBuffer]

    init(width: Int, height: Int) throws {
        buffers = try (0..<4).map { phase in
            var created: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
            guard status == kCVReturnSuccess, let buffer = created else { throw CheckError.pixelBuffer(status) }
            let locked = CVPixelBufferLockBaseAddress(buffer, [])
            guard locked == kCVReturnSuccess else { throw CheckError.pixelBuffer(locked) }
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw CheckError.bitmapContext }
            context.setFillColor(gray: 0.94, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Fine, deterministic dashboard-like detail plus changing bars and a moving panel.
            // All pixels are generated here; no fonts, windows or desktop content are read.
            for row in stride(from: 0, to: height, by: 32) {
                for column in stride(from: 0, to: width, by: 64) {
                    let shade = CGFloat((row / 32 * 7 + column / 64 * 11) % 23) / 23
                    context.setFillColor(red: 0.12 + shade * 0.2, green: 0.25 + shade * 0.3,
                                         blue: 0.4 + shade * 0.4, alpha: 1)
                    context.fill(CGRect(x: column + 3, y: row + 3, width: 10 + (column + row) % 48, height: 3))
                    context.fill(CGRect(x: column + 3, y: row + 11, width: 8 + (column + phase * 13) % 45, height: 5))
                }
            }
            context.setFillColor(red: CGFloat(phase + 1) / 5, green: 0.45, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: width * phase / 5, y: height / 3, width: width / 5, height: height / 5))
            return buffer
        }
    }
}

private struct Counts {
    var attempted = 0, accepted = 0, refused = 0, encoded = 0, decoded = 0, invalid = 0, bytes = 0
    var failures: [String] = []
    var firstRefusedAttemptIndices: [Int] = []

    func since(_ previous: Counts) -> Counts {
        var delta = self
        delta.attempted -= previous.attempted; delta.accepted -= previous.accepted
        delta.refused -= previous.refused; delta.encoded -= previous.encoded
        delta.decoded -= previous.decoded; delta.invalid -= previous.invalid; delta.bytes -= previous.bytes
        delta.failures = Array(failures.dropFirst(previous.failures.count))
        delta.firstRefusedAttemptIndices = firstRefusedAttemptIndices.filter { $0 > previous.attempted }
            .map { $0 - previous.attempted }
        return delta
    }
}

private final class StreamResult: @unchecked Sendable {
    private let lock = NSLock()
    private let outputLock = NSLock()
    private let decoder = H264Decoder()
    let decodeEnabled: Bool
    private var counts = Counts()

    init(decodeEnabled: Bool = true) { self.decodeEnabled = decodeEnabled }

    func recordSubmission(accepted: Bool) {
        lock.lock(); defer { lock.unlock() }
        counts.attempted += 1
        if accepted {
            counts.accepted += 1
        } else {
            counts.refused += 1
            if counts.firstRefusedAttemptIndices.count < 8 { counts.firstRefusedAttemptIndices.append(counts.attempted) }
        }
    }

    func accept(_ unit: H264Encoder.EncodedUnit) {
        // Serial native decode must not hold the accounting lock: otherwise recording the
        // next attempted submission would wait for the receiver and disguise source overload.
        outputLock.lock(); defer { outputLock.unlock() }
        lock.lock()
        let frame = EncodedVideoFrame(width: unit.width, height: unit.height, sequence: UInt64(counts.encoded),
            isKeyframe: unit.isKeyframe, payload: unit.payload, sps: unit.sps, pps: unit.pps)
        counts.encoded += 1; counts.bytes += unit.payload.count
        lock.unlock()
        guard frame.isValid else { lock.lock(); counts.invalid += 1; lock.unlock(); return }
        if decodeEnabled, decoder.decode(frame) != nil {
            lock.lock(); counts.decoded += 1; lock.unlock()
        }
    }

    func fail(_ reason: String) { lock.lock(); counts.failures.append(reason); lock.unlock() }
    func snapshot() -> Counts { lock.lock(); defer { lock.unlock() }; return counts }
    var isComplete: Bool {
        let value = snapshot()
        return value.encoded == value.accepted && (!decodeEnabled || value.decoded == value.encoded)
    }

    func report(elapsed: TimeInterval? = nil, since baseline: Counts = Counts()) -> [String: Any] {
        let value = snapshot().since(baseline)
        var result: [String: Any] = [
            "attempted": value.attempted, "accepted": value.accepted, "refused": value.refused,
            "encoded": value.encoded, "decoded": value.decoded, "invalid": value.invalid,
            "bytes": value.bytes, "failures": value.failures, "decodeEnabled": decodeEnabled,
            "firstRefusedAttemptIndices": value.firstRefusedAttemptIndices
        ]
        if let elapsed {
            result["encodedFramesPerSecond"] = Double(value.encoded) / max(elapsed, 0.000_001)
            result["decodedFramesPerSecond"] = Double(value.decoded) / max(elapsed, 0.000_001)
        }
        return result
    }
}

private struct ScenarioResult {
    let success: Bool
    let report: [String: Any]
}

private struct DrainMeasurement: Sendable {
    let perEncoderMilliseconds: [Double]
    let totalMilliseconds: Double
    let mainActorProbeMilliseconds: Double
}

@main struct HardwareVideoChecks {
    private static let sizes = [(1920, 1080), (1080, 1920), (1920, 1080), (1080, 1920)]

    static func main() async {
        // A native stall must fail this owned diagnostic process instead of hanging a CI job.
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            FileHandle.standardError.write(Data("Hardware codec checks exceeded the 90-second deadline.\n".utf8))
            exit(2)
        }
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.isEmpty || arguments == ["--geometry-probe"] else {
                FileHandle.standardError.write(Data("Usage: hardware-video-checks [--geometry-probe]\n".utf8))
                exit(2)
            }
            let result = try await Task.detached(priority: .userInitiated) {
                try await (arguments.isEmpty ? run() : geometryProbe())
            }.value
            print(String(data: try JSONSerialization.data(withJSONObject: result.report,
                options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
            exit(result.success ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("Hardware codec checks failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Isolate native dimension support from the four-stream load and lifecycle scenarios.
    /// Every case retires its encoder/decoder before the next; this is a diagnostic matrix,
    /// not an alternative passing route for the full test command.
    private static func geometryProbe() async throws -> ScenarioResult {
        let probes = [(1888, 4476), (1538, 5472), (1728, 4096), (1152, 4096), (1728, 4098), (1728, 4160)]
        var results: [ScenarioResult] = []
        for size in probes {
            results.append(try await scenario(name: "isolated\(size.0)x\(size.1)", sizes: [size], attempts: 30, paced: true))
        }
        let success = results.allSatisfy(\.success)
        return ScenarioResult(success: success, report: [
            "timestamp": ISO8601DateFormatter().string(from: Date()), "synthetic": true,
            "diagnosticOnly": true, "physicalHeadsetVerified": false, "success": success,
            "scenarios": results.map(\.report)
        ])
    }

    private static func run() async throws -> ScenarioResult {
        let paced = try await scenario(name: "pacedFourStreams", sizes: sizes, attempts: 150, paced: true)
        let overloaded = try await scenario(name: "boundedAdmissionOverload", sizes: sizes, attempts: 1_024, paced: false)
        let nativeTallSizes = [(2160, 5120), (2160, 7680)]
        let safeTallSizes = try nativeTallSizes.map { size in
            let safe = try DisplayCaptureSize(pixelWidth: size.0, aspectWidth: size.0, aspectHeight: size.1, format: .h264)
            return (safe.width, safe.height)
        }
        var edge: [ScenarioResult] = []
        for (index, size) in safeTallSizes.enumerated() {
            let native = nativeTallSizes[index]
            edge.append(try await scenario(name: "safeTallGeometry\(native.0)x\(native.1)", sizes: [size], attempts: 30, paced: true))
        }
        let stop = try await stopRestartMeasurements()
        let success = paced.success && overloaded.success && edge.allSatisfy(\.success) && stop.success
        return ScenarioResult(success: success, report: [
            "timestamp": ISO8601DateFormatter().string(from: Date()), "synthetic": true,
            "physicalHeadsetVerified": false, "desktopCaptured": false, "inputPosted": false,
            "pixelsSaved": false, "success": success,
            "successCriteria": "Every cold-start attempt is accounted for, and every accepted frame decodes. Steady-state paced scenarios accept and decode every attempt; overload refuses work and drains every accepted frame; repeated stops reject later submissions and emit no late output. Throughput and drain latency are measurements, not machine-specific pass/fail thresholds.",
            "limitations": "Codec-only synthetic tests. No ScreenCaptureKit, transport, SwiftUI rendering, physical headset, or long-session leak measurement. Stop responsiveness is measured and reported separately from functional success.",
            "scenarios": [paced.report, overloaded.report] + edge.map(\.report), "stopRestart": stop.report
        ])
    }

    private static func makeFrames(sizes: [(Int, Int)]) throws -> [SyntheticFrames] {
        var cached: [String: SyntheticFrames] = [:]
        return try sizes.map { size in
            let key = "\(size.0)x\(size.1)"
            if let existing = cached[key] { return existing }
            let created = try SyntheticFrames(width: size.0, height: size.1)
            cached[key] = created
            return created
        }
    }

    private static func makeEncoders(sizes: [(Int, Int)], results: [StreamResult]) throws -> [H264Encoder] {
        try sizes.enumerated().map { index, size in
            let result = results[index]
            return try H264Encoder(width: size.0, height: size.1,
                onEncoded: { result.accept($0) }, onFailure: { result.fail($0) })
        }
    }

    private static func submit(_ encoders: [H264Encoder], results: [StreamResult], frames: [SyntheticFrames], tick: Int) {
        for index in encoders.indices {
            let buffers = frames[index].buffers
            let accepted = encoders[index].encode(buffers[(tick + index) % buffers.count], at: uptime())
            results[index].recordSubmission(accepted: accepted)
        }
    }

    private static func waitForCompletion(_ results: [StreamResult], timeout: TimeInterval = 10) async throws -> Bool {
        let deadline = uptime() + timeout
        while !results.allSatisfy(\.isComplete) {
            guard uptime() < deadline else { return false }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    private static func scenario(name: String, sizes: [(Int, Int)], attempts: Int, paced: Bool) async throws -> ScenarioResult {
        let frames = try makeFrames(sizes: sizes)
        let results = sizes.map { _ in StreamResult() }
        let encoders: [H264Encoder]
        let setupStarted = uptime()
        do {
            encoders = try makeEncoders(sizes: sizes, results: results)
        } catch {
            return ScenarioResult(success: false, report: ["name": name, "success": false,
                "stage": "encoderSetup", "failure": String(describing: error),
                "sessionCreationMilliseconds": (uptime() - setupStarted) * 1_000,
                "sizes": sizes.map { ["width": $0.0, "height": $0.1] }])
        }
        let setupMilliseconds = (uptime() - setupStarted) * 1_000
        defer { encoders.forEach { $0.invalidate() } }
        var coldStart: [String: Any]?
        var coldStartSucceeded = true
        if paced {
            // Cold native allocation can refuse early frames. Preserve that observation as
            // its own phase; begin the steady-state gate only after all accepted work finishes.
            let coldAttempts = 10
            let coldStarted = uptime()
            for tick in 0..<coldAttempts {
                submit(encoders, results: results, frames: frames, tick: tick)
                let remaining = coldStarted + Double(tick + 1) / Double(H264Encoder.frameRate) - uptime()
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
            let coldComplete = try await waitForCompletion(results)
            let coldElapsed = uptime() - coldStarted
            let coldRows = results.map { result -> [String: Any] in
                let count = result.snapshot()
                var row = result.report(elapsed: coldElapsed)
                row["allAttemptsAccepted"] = count.accepted == coldAttempts
                row["success"] = coldComplete && count.attempted == coldAttempts
                    && count.accepted + count.refused == coldAttempts && count.accepted > 0
                    && count.encoded == count.accepted && count.decoded == count.encoded
                    && count.invalid == 0 && count.failures.isEmpty
                return row
            }
            coldStartSucceeded = coldRows.allSatisfy { $0["success"] as? Bool == true }
            coldStart = ["attemptsPerStream": coldAttempts, "elapsedSeconds": coldElapsed,
                         "completionDeadlineMet": coldComplete, "success": coldStartSucceeded,
                         "streams": coldRows]
            guard coldStartSucceeded else {
                return ScenarioResult(success: false, report: ["name": name, "success": false,
                    "stage": "coldStart", "sessionCreationMilliseconds": setupMilliseconds,
                    "coldStart": coldStart!])
            }
        }
        let baseline = results.map { $0.snapshot() }
        let started = uptime()
        for tick in 0..<attempts {
            submit(encoders, results: results, frames: frames, tick: tick)
            if tick == attempts / 2 { encoders.forEach { $0.requestKeyframe() } }
            if paced {
                // Absolute deadlines include submission time rather than quietly lowering the
                // requested rate by sleeping a full frame interval after every submission.
                let remaining = started + Double(tick + 1) / Double(H264Encoder.frameRate) - uptime()
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
        }
        let submissionElapsed = uptime() - started
        let complete = try await waitForCompletion(results)
        let elapsed = uptime() - started
        let rows = results.enumerated().map { index, result -> [String: Any] in
            var row = result.report(elapsed: elapsed, since: baseline[index])
            row["width"] = sizes[index].0; row["height"] = sizes[index].1
            let count = result.snapshot().since(baseline[index])
            let accounting = count.attempted == attempts && count.accepted + count.refused == attempts
                && count.encoded == count.accepted && count.decoded == count.encoded
                && count.invalid == 0 && count.failures.isEmpty
            let admission = paced ? count.accepted == attempts : count.accepted > 0 && count.refused > 0
            row["success"] = complete && accounting && admission
            return row
        }
        let success = coldStartSucceeded && rows.allSatisfy { $0["success"] as? Bool == true }
        var report: [String: Any] = ["name": name, "success": success,
            "paced": paced, "attemptsPerStream": attempts, "streamCount": sizes.count,
            "phase": paced ? "steadyState" : "overload", "sessionCreationMilliseconds": setupMilliseconds,
            "requestedFramesPerSecond": paced ? H264Encoder.frameRate : 0,
            "completionDeadlineMet": complete,
            "submissionElapsedSeconds": submissionElapsed, "elapsedSeconds": elapsed, "streams": rows]
        if let coldStart { report["coldStart"] = coldStart }
        return ScenarioResult(success: success, report: report)
    }

    @MainActor private static func measureDrain(_ encoders: [H264Encoder]) async -> DrainMeasurement {
        let queued = uptime()
        // This probe is queued before synchronous retirement. Its first instruction cannot run
        // on MainActor until all of the native calls below return. An empty baseline separates
        // ordinary executor scheduling overhead from the observed drain duration.
        let probe = Task { @MainActor in (uptime() - queued) * 1_000 }
        let started = uptime()
        var durations: [Double] = []
        for encoder in encoders {
            let before = uptime()
            encoder.invalidate()
            durations.append((uptime() - before) * 1_000)
        }
        let total = (uptime() - started) * 1_000
        return DrainMeasurement(perEncoderMilliseconds: durations, totalMilliseconds: total,
                                mainActorProbeMilliseconds: await probe.value)
    }

    private static func stopRestartMeasurements() async throws -> ScenarioResult {
        let frames = try makeFrames(sizes: sizes)
        var rows: [[String: Any]] = []
        for cycle in 0..<6 {
            // No decoder in the output callback here: this isolates encoder retirement from
            // synthetic receiver work that the production sender callback does not perform.
            let results = sizes.map { _ in StreamResult(decodeEnabled: false) }
            let encoders = try makeEncoders(sizes: sizes, results: results)
            defer { encoders.forEach { $0.invalidate() } }
            submit(encoders, results: results, frames: frames, tick: cycle)
            let warmed = try await waitForCompletion(results)
            let baseline = await measureDrain([])
            for tick in 0..<H264Encoder.maximumInFlightFrames {
                submit(encoders, results: results, frames: frames, tick: cycle + tick + 1)
            }
            let pendingBeforeStop = results.map { result in
                let count = result.snapshot()
                return max(0, count.accepted - count.encoded)
            }
            let measurement = await measureDrain(encoders)
            let afterStop = results.map { $0.snapshot() }
            let rejectsAfterStop = encoders.enumerated().map { index, encoder in
                !encoder.encode(frames[index].buffers[0], at: uptime())
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            let noLateOutput = results.enumerated().allSatisfy { index, result in
                let current = result.snapshot()
                return current.encoded == afterStop[index].encoded && current.failures == afterStop[index].failures
            }
            let validCounts = afterStop.allSatisfy {
                $0.attempted == 1 + H264Encoder.maximumInFlightFrames
                    && $0.accepted + $0.refused == $0.attempted && $0.encoded <= $0.accepted
                    && $0.encoded >= 1 && $0.invalid == 0 && $0.failures.isEmpty
            }
            rows.append(["cycle": cycle + 1, "success": warmed && validCounts && noLateOutput && rejectsAfterStop.allSatisfy { $0 },
                "warmupComplete": warmed, "pendingOutputsBeforeStop": pendingBeforeStop,
                "acceptedWithoutOutputAtStop": afterStop.map { $0.accepted - $0.encoded },
                "rejectedAfterStop": rejectsAfterStop, "noLateOutput": noLateOutput,
                "baselineMainActorProbeMilliseconds": baseline.mainActorProbeMilliseconds,
                "drainMilliseconds": measurement.totalMilliseconds,
                "perEncoderDrainMilliseconds": measurement.perEncoderMilliseconds,
                "mainActorProbeMilliseconds": measurement.mainActorProbeMilliseconds,
                "streams": results.map { $0.report() }])
        }
        let drains = rows.compactMap { $0["drainMilliseconds"] as? Double }
        let probes = rows.compactMap { $0["mainActorProbeMilliseconds"] as? Double }
        let busyCycles = rows.filter { ($0["pendingOutputsBeforeStop"] as? [Int] ?? []).contains { $0 > 0 } }.count
        let success = busyCycles > 0 && rows.allSatisfy { $0["success"] as? Bool == true }
        return ScenarioResult(success: success, report: ["success": success, "cycleCount": rows.count,
            "busyCycles": busyCycles, "maximumDrainMilliseconds": drains.max() ?? 0,
            "maximumMainActorProbeMilliseconds": probes.max() ?? 0,
            "reviewThresholdMilliseconds": 50, "reviewThresholdExceeded": (drains.max() ?? 0) > 50,
            "measurementScope": "Production H264Encoder.invalidate on MainActor with up to two submitted frames per encoder; no ScreenCaptureKit stop or app UI. Pending accepted output may intentionally be suppressed by invalidate.",
            "cycles": rows])
    }
}
