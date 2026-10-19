import AppKit
import Combine
import Foundation
import DeskTransport

/// Explicit local diagnostic: runs production capture for 15 seconds, records metadata,
/// then stops sharing. It never enables input or saves screen pixels or the pairing key.
@MainActor
final class CaptureCheck {
    /// Diagnostics use temporary pairing and availability. Running a capture check must not
    /// create a saved credential or turn off the owner's remembered sharing preferences.
    static func makeModel() -> CompanionModel {
        let key = PairingKey.generate()
        return CompanionModel(loadLANKey: { key }, saveLANKey: { _ in },
                              saveLANConfiguration: { _ in }, saveRemoteConfiguration: { _ in })
    }

    private var subscription: AnyCancellable?
    private var counts: [UInt32: Int] = [:]
    private var lastDelivery: [UInt32: TimeInterval] = [:]
    private var largestGap: [UInt32: TimeInterval] = [:]

    func run(model: CompanionModel) async {
        guard model.screenPermission, !model.sharing, !model.busy else {
            write(["success": false, "reason": "Recording permission or an idle companion is required."])
            return
        }
        // Every delivered image counts, idle repeats included, which is what proves capture is
        // alive. Thumbnails are coalesced and skip identical repeats, so they no longer can.
        subscription = model.imageDelivered.sink { [weak self] id in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.counts[id, default: 0] += 1
            if let previous = self.lastDelivery[id] {
                self.largestGap[id] = max(self.largestGap[id, default: 0], now - previous)
            }
            self.lastDelivery[id] = now
        }
        model.start()
        do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch {
            subscription = nil
            model.stop()
            write(["success": false, "reason": "Capture diagnostic cancelled."])
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let rows: [[String: Any]] = model.displays.map { display in
            let age = lastDelivery[display.id].map { now - $0 }
            return ["displayID": display.id, "name": display.name,
                    "decodedFrames": counts[display.id, default: 0],
                    "encodedH264Frames": model.encodedFrameCounts[display.id, default: 0],
                    "largestDeliveryGapSeconds": largestGap[display.id, default: 0],
                    "lastFrameAgeSeconds": age.map { $0 as Any } ?? NSNull(),
                    "fresh": age.map { $0 < 2.5 } ?? false]
        }
        let success = model.sharing && !model.busy && !rows.isEmpty
            && model.displays.allSatisfy {
                counts[$0.id, default: 0] >= 2
                    && model.encodedFrameCounts[$0.id, default: 0] >= 2
                    && lastDelivery[$0.id].map { now - $0 < 2.5 } == true
                    && largestGap[$0.id, default: 0] < 2.5
            }
        let captureStatus = model.status
        let encoders = model.videoEncoderCount
        let encodedBytes = model.encodedByteCount
        subscription = nil
        model.stop()
        write(["success": success, "durationSeconds": 15, "displayCount": rows.count,
               "displays": rows, "statusBeforeStop": captureStatus,
               "sharingStopped": !model.sharing, "inputEnabled": model.controlEnabled,
               "hardwareH264EncoderCount": encoders, "encodedByteCount": encodedBytes,
               "physicalHeadsetVerified": false])
    }

    private func write(_ report: [String: Any]) {
        var dated = report
        dated["timestamp"] = ISO8601DateFormatter().string(from: Date())
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("capture-check.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: dated, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch { NSLog("VisionDesk capture check could not save metadata: %@", error.localizedDescription) }
    }
}
