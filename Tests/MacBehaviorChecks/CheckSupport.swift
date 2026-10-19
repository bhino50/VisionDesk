import CoreGraphics
import CoreVideo
import DeskCore
import DeskTransport
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CheckError: Error {
    /// Returned by the injected content provider so no check ever reaches ScreenCaptureKit.
    case preparationAbandoned
}

/// Holds `CompanionModel.start()` inside its injected content provider so Stop can arrive
/// while preparation is still suspended, without any capture permission being involved.
@MainActor
final class PreparationGate {
    private(set) var wasEntered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func waitUntilReleased() async {
        wasEntered = true
        guard !isReleased else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let pending = waiter
        waiter = nil
        pending?.resume()
    }
}

/// Records frame deliveries. Only ever touched on the main actor, where
/// `LatestFrameDelivery` invokes its callback.
final class FrameLog: @unchecked Sendable {
    private(set) var entries: [(id: UInt32, jpeg: Data)] = []
    var count: Int { entries.count }

    func append(id: UInt32, jpeg: Data) { entries.append((id: id, jpeg: jpeg)) }
}

/// Runs queued main-actor work, including deliveries and notifications scheduled from
/// other queues. `Task.yield` alone does not drain the main dispatch queue.
func drainMainActor(rounds: Int = 8) async {
    for _ in 0..<rounds {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Polls on the main actor until `condition` holds or `seconds` pass.
@MainActor
func waitUntil(seconds: Double, _ condition: () -> Bool) async {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// Records keep-awake hold and release calls instead of creating a real power assertion, so no
/// check can keep this Mac awake or let it sleep.
final class KeepAwakeRecorder {
    private(set) var begins = 0
    private(set) var ends = 0
    lazy var hold = KeepAwakeHold(begin: { [unowned self] in self.begins += 1; return NSObject() },
                                  end: { [unowned self] _ in self.ends += 1 })
}

/// A clock the checks advance by hand. Injected as `CompanionModel`'s uptime, it steps through
/// notice grace windows and the recovery keep-awake window without waiting minutes for them.
final class ManualClock {
    private(set) var now: TimeInterval

    init(start: TimeInterval = 50_000) { now = start }

    func advance(by seconds: TimeInterval) { now += seconds }
}

/// A syntactically valid unattended configuration. Every check that uses it also injects the
/// pairing-key loader, so the real Keychain is never read.
let checkRemoteConfiguration = RemoteHostConfiguration(enabled: true, address: "100.64.0.1:58271", allowControl: false, keepAwake: true)

/// The interface addresses a check's model sees: loopback and every Tailscale address the checks
/// configure, so no check depends on whether this Mac has Tailscale connected.
func checkLocalAddresses() -> [String] { ["127.0.0.1", "100.64.0.1", "100.64.0.10"] }

/// Remote access storage in memory. A check's model loads, saves and forgets its pairing key and
/// saves its preferences here, so no check reads or writes the login Keychain or user defaults.
final class RemoteStorageRecorder {
    var key: PairingKey?
    private(set) var keySaves = 0
    private(set) var keyDeletes = 0
    private(set) var savedConfigurations: [RemoteHostConfiguration] = []

    init(key: PairingKey? = nil) { self.key = key }

    func load() throws -> PairingKey? { key }
    func save(_ new: PairingKey) throws { keySaves += 1; key = new }
    func delete() throws { keyDeletes += 1; key = nil }
    func saveConfiguration(_ configuration: RemoteHostConfiguration) { savedConfigurations.append(configuration) }
}

/// Accessibility as a check needs it, answered without asking this Mac.
func controlAccess(_ allowed: Bool) -> InputPermissionCache {
    InputPermissionCache(isTrusted: { allowed }, canPostEvents: { allowed })
}

func syntheticDisplay(_ id: UInt32, pointWidth: Double = 1_920) -> DisplayInfo {
    DisplayInfo(id: id, name: "Synthetic \(id)", width: 1_920, height: 1_080,
                originX: (Double(id) - 1) * 1_920, originY: 0, pointWidth: pointWidth, pointHeight: 1_080)
}

func syntheticVideoFrame(_ sequence: UInt64, keyframe: Bool) -> EncodedVideoFrame {
    EncodedVideoFrame(width: 64, height: 64, sequence: sequence, isKeyframe: keyframe,
                      payload: Data([0, 0, 0, 1, keyframe ? 0x65 : 0x41]),
                      sps: keyframe ? Data([0x67, 0x42]) : nil, pps: keyframe ? Data([0x68, 0xCE]) : nil)
}

/// A real JPEG whose pixel width is `width`, so a thumbnail can be traced back to its source.
func syntheticJPEG(width: Int) -> Data {
    let data = NSMutableData()
    guard let context = CGContext(data: nil, width: width, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
    context.setFillColor(CGColor(red: Double(width % 256) / 255, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 8))
    guard let image = context.makeImage() else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : Data()
}

/// A desktop-like BGRA frame — flat panels, a gradient and dense one-pixel strokes — built in
/// memory. Nothing is captured; this only gives the production encoder realistic work.
func syntheticPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created) == kCVReturnSuccess,
          let buffer = created else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let panel = (x / 480 + y / 270) % 2 == 0
            let stroke = y % 18 < 2 && x % 7 != 0 && (x / 96) % 3 != 2
            let shade: UInt8 = stroke ? 24 : (panel ? 236 : UInt8(truncatingIfNeeded: (x + y) / 12))
            row[x * 4] = shade
            row[x * 4 + 1] = shade
            row[x * 4 + 2] = panel ? 242 : shade
            row[x * 4 + 3] = 255
        }
    }
    return buffer
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}

func milliseconds(_ value: Double) -> String { String(format: "%.2f", value) }
