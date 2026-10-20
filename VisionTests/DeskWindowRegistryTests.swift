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
    func testMissingNativeSessionCanBeOpenedAgain() {
        let registry = DeskWindowRegistry()
        registry.register(.display(1), owner: UUID(), sessionID: "stale")
        var created = 0
        registry.open(.display(1)) { created += 1 }
        XCTAssertFalse(registry.isOpen(1))
        XCTAssertNotNil(registry.message)
        registry.open(.display(1)) { created += 1 }
        XCTAssertEqual(created, 1)
    }

    func testLateActivationFailurePreservesReplacementRegistration() {
        let registry = DeskWindowRegistry()
        registry.register(.display(1), owner: UUID(), sessionID: "old")
        let captured = registry.entries
        registry.sceneDisconnected("old")
        let replacement = UUID()
        registry.register(.display(1), owner: replacement, sessionID: "new")
        registry.activationFailed(captured)
        XCTAssertEqual(registry.entries[.display(1)]?.owner, replacement)
        XCTAssertNil(registry.message)
    }

    func testSceneDisconnectReleasesOnlyItsWindows() {
        let registry = DeskWindowRegistry()
        registry.register(.display(1), owner: UUID(), sessionID: "one")
        registry.register(.display(2), owner: UUID(), sessionID: "two")
        registry.sceneDisconnected("one")
        XCTAssertFalse(registry.isOpen(1))
        XCTAssertTrue(registry.isOpen(2))
    }

    func testAnchorDetachReleasesRegistrationAndAllowsReopening() {
        let registry = DeskWindowRegistry()
        let anchor = DeskWindowAnchor.Anchor()
        anchor.registry = registry
        anchor.key = .display(1)
        anchor.reconcileBinding(sessionID: "one") {
            registry.register(.display(1), owner: anchor.owner, sessionID: "one")
        }
        anchor.reconcileBinding(sessionID: nil, attach: {})
        var created = false
        registry.open(.display(1)) { created = true }
        XCTAssertTrue(created)
        XCTAssertNil(anchor.boundKey)
    }

    func testAnchorReattachmentToSameSessionKeepsWindowAndMoveReplacesIt() {
        let registry = DeskWindowRegistry(activate: { _ in }, destroy: { _ in })
        let anchor = DeskWindowAnchor.Anchor()
        anchor.registry = registry
        anchor.key = .display(1)
        for session in ["one", "one", "two"] {
            anchor.reconcileBinding(sessionID: session) {
                registry.register(.display(1), owner: anchor.owner, sessionID: session)
            }
            XCTAssertEqual(registry.entries[.display(1)]?.sessionID, session)
        }
        XCTAssertEqual(registry.openDisplayCount, 1)
    }

    func testActivationFailureReleasesCapturedEntryForNextTap() {
        let registry = DeskWindowRegistry(activate: { _ in })
        registry.register(.display(1), owner: UUID(), sessionID: "one")
        registry.activationFailed(registry.entries)
        var created = false
        registry.open(.display(1)) { created = true }
        XCTAssertTrue(created)
    }

    func testDetachedOldAnchorCannotRemoveReplacementOwner() {
        let registry = DeskWindowRegistry()
        let anchor = DeskWindowAnchor.Anchor()
        anchor.registry = registry
        anchor.key = .display(1)
        anchor.reconcileBinding(sessionID: "one") {
            registry.register(.display(1), owner: anchor.owner, sessionID: "one")
        }
        let replacement = UUID()
        registry.register(.display(1), owner: replacement, sessionID: "one")
        anchor.reconcileBinding(sessionID: nil, attach: {})
        XCTAssertEqual(registry.entries[.display(1)]?.owner, replacement)
    }

}
