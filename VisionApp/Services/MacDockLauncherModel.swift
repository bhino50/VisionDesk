import Combine
import DeskCore
import Foundation
import ImageIO
import UIKit

/// A catalog and one correlated request, scoped to the authenticated Mac session.
/// The parent supplies its live control gates and its sole transport send path.
@MainActor
final class MacDockLauncherModel: ObservableObject {
    @Published private(set) var apps: [DockAppInfo] = []
    @Published private(set) var icons: [String: UIImage] = [:]
    @Published private(set) var isAvailable = false
    @Published private(set) var supportsPlacement = false
    @Published private(set) var launchingAppID: String?
    @Published private(set) var launchStatus: String?
    @Published private(set) var launchSucceeded: Bool?

    var canLaunch: () -> Bool = { false }
    var canRefresh: () -> Bool = { false }
    var send: (DeskMessage) -> Bool = { _ in false }

    private let timeoutNanoseconds: UInt64
    private var sessionID: UUID?
    private var requestID: String?
    private var timeoutTask: Task<Void, Never>?

    init(timeoutNanoseconds: UInt64 = 10_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    var isLaunching: Bool { requestID != nil }

    func beginSession(_ id: UUID) {
        endSession()
        sessionID = id
    }

    func endSession() {
        timeoutTask?.cancel()
        timeoutTask = nil
        requestID = nil
        sessionID = nil
        apps = []
        icons = [:]
        isAvailable = false
        supportsPlacement = false
        launchingAppID = nil
        launchStatus = nil
        launchSucceeded = nil
    }

    func refresh() {
        guard sessionID != nil, isAvailable, canRefresh() else { return }
        _ = send(DeskMessage(kind: "requestApps"))
    }

    func launch(appID: String, displayID: UInt32? = nil) {
        guard displayID == nil || supportsPlacement,
              let session = sessionID, isAvailable, !isLaunching, canLaunch(),
              let app = apps.first(where: { $0.id == appID }) else { return }
        let request = UUID().uuidString
        requestID = request
        launchingAppID = appID
        launchSucceeded = nil
        launchStatus = "Opening \(app.name) on your Mac…"
        // A failed send may synchronously tear down this entire session.
        guard send(DeskMessage(kind: "launchApp", displayID: displayID, appID: appID, appRequestID: request)),
              sessionID == session, requestID == request else { return }
        timeoutTask = Task { @MainActor [weak self] in
            guard let duration = self?.timeoutNanoseconds else { return }
            do { try await Task.sleep(nanoseconds: duration) }
            catch { return }
            guard let self, self.sessionID == session, self.requestID == request else { return }
            self.finish(status: "No confirmation yet. Check your Mac before trying again.", succeeded: false)
        }
    }

    /// Cancels local waiting, not a request that may already be executing on the Mac.
    func controlBecameUnavailable() {
        guard isLaunching else { return }
        finish(status: "Control paused. Check your Mac; the app request may already have reached it.", succeeded: false)
    }

    func receive(_ message: DeskMessage) {
        guard sessionID != nil, message.isValid else { return }
        switch message.kind {
        case "apps":
            guard let catalog = message.dockApps else { return }
            // Decode once per catalog, never once per UI redraw or launch-status update.
            icons = Dictionary(uniqueKeysWithValues: catalog.compactMap { app in
                guard let data = app.iconPNG, let image = Self.decodeIcon(data) else { return nil }
                return (app.id, image)
            })
            apps = catalog
            supportsPlacement = message.appPlacement == true
            isAvailable = true
        case "appLaunchResult":
            guard let requestID, message.appRequestID == requestID,
                  message.appID == launchingAppID, let succeeded = message.appLaunchSucceeded else { return }
            finish(status: message.status ?? (succeeded ? "Opened on your Mac." : "Your Mac could not open this app."),
                   succeeded: succeeded)
        default: break
        }
    }

    /// Validate compressed-image metadata before allocating decoded pixels. A byte-limited PNG
    /// can still claim an enormous bitmap; thumbnails keep normal icons inexpensive too.
    static func decodeIcon(_ data: Data) -> UIImage? {
        guard !data.isEmpty, data.count <= 16 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), type as String == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1...256).contains(width.doubleValue), (1...256).contains(height.doubleValue),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private func finish(status: String, succeeded: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        requestID = nil
        launchingAppID = nil
        launchStatus = status
        launchSucceeded = succeeded
    }
}
