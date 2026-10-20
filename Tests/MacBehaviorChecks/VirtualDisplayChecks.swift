import Foundation

private final class FakeVirtualDisplay: VirtualDisplayHandle {
    let displayID: UInt32
    var invalidations = 0
    init(_ id: UInt32) { displayID = id }
    func invalidate() { invalidations += 1 }
}

@MainActor
func runVirtualDisplayChecks(_ runner: CheckRunner) async {
    await runner.check("Extra desktops are explicit, bounded, and reusable after removal") {
        var handles: [FakeVirtualDisplay] = []
        var names: [String] = []
        let manager = VirtualDisplayManager(backend: .init(isSupported: true, create: { name in
            let handle = FakeVirtualDisplay(UInt32(handles.count + 100))
            handles.append(handle)
            names.append(name)
            return handle
        }))
        runner.expect(handles.isEmpty && manager.desktops.isEmpty, "initialization never creates a desktop")
        runner.expectEqual(manager.create(), 100, "first desktop ID")
        runner.expectEqual(manager.create(), 101, "second desktop ID")
        runner.expectEqual(manager.create(), 102, "third desktop ID")
        runner.expect(manager.create() == nil && manager.errorMessage != nil, "fourth creation explains the limit")
        runner.expectEqual(handles.count, 3, "limit does not call backend")
        manager.remove(id: 101)
        manager.remove(id: 101)
        runner.expectEqual(handles[1].invalidations, 1, "removal is idempotent")
        runner.expectEqual(manager.create(), 103, "removed capacity is reusable")
        runner.expectEqual(names.last, "VisionDesk Desktop 2", "available desktop name is reused")
        manager.removeAll()
        manager.removeAll()
        runner.expect(manager.desktops.isEmpty, "all desktops are removed")
        runner.expect(handles.allSatisfy { $0.invalidations == 1 }, "each owned desktop is released once")
    }
    await runner.check("Extra desktop backend failures do not leak or publish invalid IDs") {
        var attempts = 0
        let unsupported = VirtualDisplayManager(backend: .init(isSupported: false, create: { _ in
            attempts += 1
            return FakeVirtualDisplay(1)
        }))
        runner.expect(unsupported.create() == nil && unsupported.errorMessage != nil, "unsupported backend explains failure")
        runner.expectEqual(attempts, 0, "unsupported systems never invoke creation")
        let failed = VirtualDisplayManager(backend: .init(isSupported: true, create: { _ in
            throw NSError(domain: "VirtualDisplayTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Creation failed"])
        }))
        runner.expect(failed.create() == nil && failed.desktops.isEmpty, "throwing backend publishes no desktop")
        runner.expectEqual(failed.errorMessage, "Creation failed", "failure reaches owner")
        let zero = FakeVirtualDisplay(0)
        let invalid = VirtualDisplayManager(backend: .init(isSupported: true, create: { _ in zero }))
        runner.expect(invalid.create() == nil && invalid.desktops.isEmpty, "zero ID is rejected")
        runner.expectEqual(zero.invalidations, 1, "invalid native resource is cleaned up")
        let first = FakeVirtualDisplay(42)
        let duplicate = FakeVirtualDisplay(42)
        var issued = false
        let repeated = VirtualDisplayManager(backend: .init(isSupported: true, create: { _ in
            defer { issued = true }
            return issued ? duplicate : first
        }))
        _ = repeated.create()
        runner.expect(repeated.create() == nil, "duplicate runtime ID is rejected")
        runner.expectEqual(repeated.desktops.count, 1, "existing desktop remains owned")
        runner.expectEqual(duplicate.invalidations, 1, "duplicate resource is cleaned up")
        runner.expectEqual(first.invalidations, 0, "existing resource is preserved")
        repeated.removeAll()
    }
    await runner.check("Extra desktops are released when their manager is destroyed") {
        let handle = FakeVirtualDisplay(77)
        var manager: VirtualDisplayManager? = VirtualDisplayManager(backend: .init(isSupported: true, create: { _ in handle }))
        _ = manager?.create()
        manager = nil
        runner.expectEqual(handle.invalidations, 1, "deinitialization cleans up the owned desktop")
    }
}
