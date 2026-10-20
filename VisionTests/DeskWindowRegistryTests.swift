import XCTest
@testable import VisionDesk

@MainActor
final class DeskWindowRegistryTests: XCTestCase {
    func testRapidRepeatedDisplayOpensReserveExactlyOneCreation() {
        var time: TimeInterval = 0, created = 0
        let registry = DeskWindowRegistry(now: { time })
        for _ in 0..<20 { registry.open(.display(7)) { created += 1 } }
        XCTAssertEqual(created, 1)
        time = 6
        registry.open(.display(7)) { created += 1 }
        XCTAssertEqual(created, 2, "A native creation failure must remain recoverable.")
    }

    func testExistingScreenAndOverviewAreActivatedRatherThanRecreated() {
        var activations: [String] = [], created = 0
        let registry = DeskWindowRegistry(activate: { activations.append($0) })
        let owner = UUID()
        XCTAssertTrue(registry.register(.display(7), owner: owner, sessionID: "screen-7"))
        XCTAssertTrue(registry.register(.overview, owner: UUID(), sessionID: "overview"))
        for _ in 0..<10 {
            registry.open(.display(7)) { created += 1 }
            registry.open(.overview) { created += 1 }
        }
        XCTAssertEqual(created, 0)
        XCTAssertEqual(activations.filter { $0 == "screen-7" }.count, 10)
        XCTAssertEqual(activations.filter { $0 == "overview" }.count, 10)
        XCTAssertEqual(registry.openDisplayCount, 1)
    }

    func testDuplicateRestoredSceneIsClosedWithoutLosingOriginalOwnership() {
        var destroyed: [String] = [], activated: [String] = []
        let registry = DeskWindowRegistry(activate: { activated.append($0) }, destroy: { destroyed.append($0) })
        let original = UUID(), duplicate = UUID()
        registry.register(.display(7), owner: original, sessionID: "original")
        XCTAssertFalse(registry.register(.display(7), owner: duplicate, sessionID: "duplicate"))
        XCTAssertEqual(destroyed, ["duplicate"])
        XCTAssertEqual(activated, ["original"])
        registry.unregister(.display(7), owner: duplicate)
        XCTAssertTrue(registry.isOpen(7))
        XCTAssertEqual(registry.entries[.display(7)]?.owner, original)
    }

    func testCloseAllPreservesOverviewAndReopeningWaitsForNativeClosure() {
        var destroyed: [String] = [], created = 0
        let registry = DeskWindowRegistry(destroy: { destroyed.append($0) })
        let first = UUID(), second = UUID()
        registry.register(.overview, owner: UUID(), sessionID: "overview")
        registry.register(.display(1), owner: first, sessionID: "one")
        registry.register(.display(2), owner: second, sessionID: "two")
        registry.closeAllDisplays()
        XCTAssertEqual(Set(destroyed), ["one", "two"])
        XCTAssertNotNil(registry.entries[.overview])
        registry.open(.display(1)) { created += 1 }
        XCTAssertEqual(created, 0, "A scene still closing must not be duplicated.")
        registry.unregister(.display(1), owner: first)
        registry.unregister(.display(2), owner: second)
        XCTAssertEqual(registry.openDisplayCount, 0)
        registry.open(.display(1)) { created += 1 }
        XCTAssertEqual(created, 1)
    }

    func testLateDismantleCannotUnregisterAReplacementOwner() {
        let registry = DeskWindowRegistry()
        let old = UUID(), replacement = UUID()
        registry.register(.display(1), owner: old, sessionID: "same-scene")
        registry.register(.display(1), owner: replacement, sessionID: "same-scene")
        registry.unregister(.display(1), owner: old)
        XCTAssertEqual(registry.entries[.display(1)]?.owner, replacement)
    }
}
