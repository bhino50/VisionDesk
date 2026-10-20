import AppKit
import DeskCore
import ApplicationServices

/// The remote peer receives opaque identifiers, never filesystem paths or launch arguments.
@MainActor
final class DockAppLauncher {
    struct Entry {
        let info: DockAppInfo
        let url: URL
    }
    private let discover: @MainActor () -> [URL]
    private let open: @MainActor (URL, @escaping @MainActor (pid_t?) -> Void) -> Void
    typealias RoutingAuthorization = @MainActor @Sendable () -> Bool
    typealias Route = @MainActor (pid_t, URL, DisplayInfo, @escaping RoutingAuthorization, @escaping @MainActor (Bool) -> Void) -> Void
    private let route: Route
    private var identities: [URL: String] = [:]
    private var allowed: [String: URL] = [:]

    init(discover: @escaping @MainActor () -> [URL] = DockAppLauncher.installedDockApps,
         open: @escaping @MainActor (URL, @escaping @MainActor (pid_t?) -> Void) -> Void = DockAppLauncher.openApplication,
         route: @escaping Route = DockWindowRouter.place) {
        self.discover = discover; self.open = open; self.route = route
    }

    func catalog() -> [DockAppInfo] {
        var entries: [Entry] = []
        var seen = Set<URL>()
        for candidate in discover() {
            guard let url = Self.validatedApplication(candidate), seen.insert(url).inserted else { continue }
            let name = Self.applicationName(at: url)
            let id = identities[url] ?? UUID().uuidString
            identities[url] = id
            let info = DockAppInfo(id: id, name: name, iconPNG: Self.icon(for: url))
            guard info.isValid else { continue }
            entries.append(Entry(info: info, url: url))
            if entries.count == DeskMessage.maximumDockApps { break }
        }
        allowed = Dictionary(uniqueKeysWithValues: entries.map { ($0.info.id, $0.url) })
        return entries.map(\.info)
    }

    func launch(id: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard let url = allowed[id], Self.validatedApplication(url) == url else { completion(false); return }
        open(url) { completion($0 != nil) }
    }

    struct LaunchOutcome {
        let opened: Bool
        let placed: Bool?
        var succeeded: Bool { opened && placed != false }
    }

    func launch(id: String, target: DisplayInfo?, canRoute: @escaping RoutingAuthorization = { true }, completion: @escaping @MainActor (LaunchOutcome) -> Void) {
        guard let url = allowed[id], Self.validatedApplication(url) == url else {
            completion(LaunchOutcome(opened: false, placed: nil)); return
        }
        open(url) { [route] pid in
            guard let pid else { completion(LaunchOutcome(opened: false, placed: nil)); return }
            guard let target else { completion(LaunchOutcome(opened: true, placed: nil)); return }
            guard canRoute() else { completion(LaunchOutcome(opened: true, placed: false)); return }
            route(pid, url, target, canRoute) { placed in completion(LaunchOutcome(opened: true, placed: placed)) }
        }
    }

    static func applicationName(at url: URL) -> String {
        if let bundle = Bundle(url: url) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = bundle.object(forInfoDictionaryKey: key) as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value.hasSuffix(".app") ? String(value.dropLast(4)) : value
                }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func validatedApplication(_ candidate: URL) -> URL? {
        guard candidate.isFileURL else { return nil }
        let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              bundle.bundleURL.standardizedFileURL == url,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return url
    }

    static func installedDockApps() -> [URL] {
        var urls = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        for key in ["persistent-apps", "recent-apps"] {
            let tiles = CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
            for tile in tiles {
                guard let data = tile["tile-data"] as? [String: Any],
                      let file = data["file-data"] as? [String: Any],
                      let value = file["_CFURLString"] as? String,
                      let url = URL(string: value), url.isFileURL else { continue }
                urls.append(url)
            }
        }
        urls += NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleURL)
        return urls
    }

    static func openApplication(_ url: URL, completion: @escaping @MainActor (pid_t?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            Task { @MainActor in completion(error == nil ? app?.processIdentifier : nil) }
        }
    }

    private static func icon(for url: URL) -> Data? {
        let source = NSWorkspace.shared.icon(forFile: url.path)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 16 * 1_024 else { return nil }
        return png
    }
}

/// Pure logical-point placement shared by the AX router and its regression checks.
enum DockWindowPlacement {
    static func frame(size: CGSize, visible: CGRect) -> CGRect? {
        guard visible.origin.x.isFinite, visible.origin.y.isFinite,
              visible.width.isFinite, visible.height.isFinite, visible.width > 0, visible.height > 0,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        return CGRect(x: visible.minX + (visible.width - width) / 2,
                      y: visible.minY + (visible.height - height) / 2, width: width, height: height)
    }
}

@MainActor
enum DockWindowRouter {
    static func place(pid: pid_t, url: URL, display: DisplayInfo, canRoute: @escaping DockAppLauncher.RoutingAuthorization, completion: @escaping @MainActor (Bool) -> Void) {
        guard canRoute(), AXIsProcessTrusted(), CGDisplayIsOnline(display.id) != 0,
              NSRunningApplication(processIdentifier: pid)?.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id }) else {
            completion(false); return
        }
        let visible = screen.visibleFrame
        // AppKit uses a bottom-left origin. Convert the local visible inset through this
        // display's CG logical top-left origin, which also works above/left and in portrait.
        let bounds = CGRect(x: display.originX + visible.minX - screen.frame.minX,
                            y: display.originY + screen.frame.maxY - visible.maxY,
                            width: visible.width, height: visible.height)
        let authorize: DockAppLauncher.RoutingAuthorization = {
            canRoute() && NSRunningApplication(processIdentifier: pid)?.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url
        }
        Task {
            let moved = await Task.detached(priority: .userInitiated) {
                await moveWindow(pid: pid, displayID: display.id, visible: bounds, authorize: authorize)
            }.value
            completion(moved)
        }
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
    }

    private nonisolated static func moveWindow(pid: pid_t, displayID: UInt32, visible: CGRect, authorize: @escaping DockAppLauncher.RoutingAuthorization) async -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard CGDisplayIsOnline(displayID) != 0, AXIsProcessTrusted(), await authorize() else { return false }
            let windows = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
            var normal: [AXUIElement] = []
            var main: AXUIElement?
            for window in windows.prefix(8) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
                AXUIElementSetMessagingTimeout(window, 0.2)
                guard attribute(window, kAXSubroleAttribute as CFString) as? String == kAXStandardWindowSubrole else { continue }
                normal.append(window)
                if attribute(window, kAXMainAttribute as CFString) as? Bool == true { main = window; break }
            }
            if let window = main ?? normal.first,
               let sizeValue = attribute(window, kAXSizeAttribute as CFString),
               CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                var size = CGSize.zero
                guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
                      let frame = DockWindowPlacement.frame(size: size, visible: visible) else { return false }
                guard await authorize(), ProcessInfo.processInfo.systemUptime < deadline else { return false }
                if attribute(window, kAXMinimizedAttribute as CFString) as? Bool == true {
                    guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success,
                          attribute(window, kAXMinimizedAttribute as CFString) as? Bool != true else { return false }
                }
                guard await authorize() else { return false }
                var desiredSize = frame.size, desiredPosition = frame.origin
                guard let resized = AXValueCreate(.cgSize, &desiredSize),
                      let positioned = AXValueCreate(.cgPoint, &desiredPosition) else { continue }
                _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, resized)
                guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positioned) == .success,
                      let actualPosition = attribute(window, kAXPositionAttribute as CFString),
                      let actualSize = attribute(window, kAXSizeAttribute as CFString),
                      CFGetTypeID(actualPosition) == AXValueGetTypeID(), CFGetTypeID(actualSize) == AXValueGetTypeID() else { continue }
                var point = CGPoint.zero, measured = CGSize.zero
                guard AXValueGetValue(actualPosition as! AXValue, .cgPoint, &point),
                      AXValueGetValue(actualSize as! AXValue, .cgSize, &measured),
                      visible.insetBy(dx: -2, dy: -2).contains(CGRect(origin: point, size: measured)),
                      attribute(window, kAXMinimizedAttribute as CFString) as? Bool != true else { continue }
                guard await authorize() else { return false }
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return true
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
        }
        return false
    }
}
