import AppKit
import Combine
import VirtualDisplayBridge

/// Kept injectable so lifecycle checks never create operating-system displays.
protocol VirtualDisplayHandle: AnyObject {
    var displayID: UInt32 { get }
    func invalidate()
}

extension VDVirtualDisplay: VirtualDisplayHandle {}

struct VirtualDisplayBackend {
    let isSupported: Bool
    let create: @MainActor (String) throws -> any VirtualDisplayHandle

    static var native: Self {
        Self(isSupported: VDVirtualDisplay.isSupported(), create: { try VDVirtualDisplay(name: $0) })
    }
}

/// Extra desktops are explicitly created and exist only while this app owns them.
/// The optional backend uses an undocumented macOS interface and is unsuitable
/// for guaranteed compatibility. Attached displays work without this backend.
@MainActor
final class VirtualDisplayManager: NSObject, ObservableObject {
    struct Desktop: Identifiable, Equatable {
        let id: UInt32
        let name: String
    }

    static let maximumDesktopCount = 3
    @Published private(set) var desktops: [Desktop] = []
    @Published private(set) var errorMessage: String?
    let isSupported: Bool
    private let backend: VirtualDisplayBackend
    private var handles: [UInt32: any VirtualDisplayHandle] = [:]

    override convenience init() { self.init(backend: .native) }

    init(backend: VirtualDisplayBackend) {
        self.backend = backend
        self.isSupported = backend.isSupported
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(removeAll),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    /// Returns the CoreGraphics ID, which joins the normal capture inventory.
    @discardableResult
    func create() -> UInt32? {
        errorMessage = nil
        guard isSupported else {
            errorMessage = "Extra desktops are unavailable on this version of macOS."
            return nil
        }
        guard desktops.count < Self.maximumDesktopCount else {
            errorMessage = "You can create up to three extra desktops."
            return nil
        }
        let usedNames = Set(desktops.map(\.name))
        let number = (1...Self.maximumDesktopCount).first { !usedNames.contains("VisionDesk Desktop \($0)") } ?? 1
        let name = "VisionDesk Desktop \(number)"
        do {
            let handle = try backend.create(name)
            let id = handle.displayID
            guard id != 0, handles[id] == nil else {
                handle.invalidate()
                errorMessage = "macOS returned an invalid extra desktop."
                return nil
            }
            handles[id] = handle
            desktops.append(Desktop(id: id, name: name))
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func remove(id: UInt32) {
        handles.removeValue(forKey: id)?.invalidate()
        desktops.removeAll { $0.id == id }
        errorMessage = nil
    }

    @objc func removeAll() {
        for handle in handles.values { handle.invalidate() }
        handles.removeAll()
        desktops.removeAll()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for handle in handles.values { handle.invalidate() }
    }
}
