import Combine
import Foundation
import XCTest
import UIKit
@testable import VisionDesk

@MainActor
final class DisplayWindowActivityTests: XCTestCase {
    func testDragActivityCarriesOnlyCanonicalLocalDisplayNavigation() {
        for id: UInt32 in [1, 10, UInt32.max] {
            let activity = DisplayWindowActivity.make(displayID: id)
            XCTAssertEqual(DisplayWindowActivity.displayID(from: activity), id)
            XCTAssertTrue(activity.userInfo?.isEmpty != false)
            XCTAssertNil(activity.webpageURL)
            XCTAssertFalse(activity.isEligibleForHandoff)
            XCTAssertFalse(activity.isEligibleForSearch)
            XCTAssertFalse(activity.isEligibleForPublicIndexing)
        }
        XCTAssertFalse(DisplayWindowActivity.target(for: 10).contains(DisplayWindowActivity.target(for: 1)))
    }

    func testMalformedOrForeignActivitiesNeverSelectADisplay() {
        let activity = NSUserActivity(activityType: DisplayWindowActivity.activityType)
        for target: String? in [nil, "", "visiondesk-display:0:", "visiondesk-display:01:",
                                "visiondesk-display:-1:", "visiondesk-display:4294967296:",
                                "visiondesk-display:1:extra", "visiondesk-display:1"] {
            activity.targetContentIdentifier = target
            XCTAssertNil(DisplayWindowActivity.displayID(from: activity))
        }
        let foreign = NSUserActivity(activityType: "unrelated.activity")
        foreign.targetContentIdentifier = DisplayWindowActivity.target(for: 1)
        XCTAssertNil(DisplayWindowActivity.displayID(from: foreign))
    }

    func testInAppScreenRequestReservesCreationAndReusesExistingNativeWindow() {
        var requests: [UInt32] = [], activated: [String] = []
        let registry = DeskWindowRegistry(activate: { activated.append($0) })
        let request: (UInt32, @escaping () -> Void) -> Void = { id, _ in requests.append(id) }

        for _ in 0..<5 { DisplayWindowActivity.open(displayID: 7, registry: registry, request: request) }
        XCTAssertEqual(requests, [7], "Repeated in-app actions must not create duplicate windows.")
        registry.register(.display(7), owner: UUID(), sessionID: "screen-7")
        DisplayWindowActivity.open(displayID: 7, registry: registry, request: request)
        XCTAssertEqual(requests, [7])
        XCTAssertEqual(activated, ["screen-7"])
    }

    func testInAppScreenRequestFailureAllowsRetryAndIgnoresLateFailure() {
        let registry = DeskWindowRegistry()
        var failures: [() -> Void] = []
        let request: (UInt32, @escaping () -> Void) -> Void = { _, failed in failures.append(failed) }

        DisplayWindowActivity.open(displayID: 7, registry: registry, request: request)
        XCTAssertEqual(failures.count, 1)
        failures[0]()
        XCTAssertNotNil(registry.message)
        DisplayWindowActivity.open(displayID: 7, registry: registry, request: request)
        XCTAssertEqual(failures.count, 2)
        XCTAssertNil(registry.message)

        failures[0]()
        DisplayWindowActivity.open(displayID: 7, registry: registry, request: request)
        XCTAssertEqual(failures.count, 2, "An older failure cannot release the newer reservation.")
        registry.register(.display(7), owner: UUID(), sessionID: "screen-7")
        failures[1]()
        XCTAssertTrue(registry.isOpen(7), "A late failure cannot remove the window that opened.")
        XCTAssertNil(registry.message)
    }

    func testCreationFailureCanBeRetriedAndLateFailureCannotEraseAnOpenWindow() throws {
        var created = 0
        let registry = DeskWindowRegistry()
        registry.open(.display(7)) { created += 1 }
        let first = try XCTUnwrap(registry.openingToken(for: .display(7)))
        registry.creationFailed(.display(7), token: first)
        XCTAssertNotNil(registry.message)
        registry.open(.display(7)) { created += 1 }
        XCTAssertEqual(created, 2)
        registry.register(.display(7), owner: UUID(), sessionID: "live")
        registry.creationFailed(.display(7), token: first)
        XCTAssertTrue(registry.isOpen(7))
    }


    func testLateCreationFailureCannotClearANewerPendingRequest() throws {
        var time: TimeInterval = 0, created = 0
        let registry = DeskWindowRegistry(now: { time })
        registry.open(.display(7)) { created += 1 }
        let old = try XCTUnwrap(registry.openingToken(for: .display(7)))
        time = 6
        registry.open(.display(7)) { created += 1 }
        let current = try XCTUnwrap(registry.openingToken(for: .display(7)))
        registry.creationFailed(.display(7), token: old)
        registry.open(.display(7)) { created += 1 }
        XCTAssertEqual(created, 2)
        XCTAssertEqual(registry.openingToken(for: .display(7)), current)
        XCTAssertNil(registry.message)
    }

    func testAnchorDismantlePublishesRemovalAfterTheViewUpdateReturns() async throws {
        let registry = DeskWindowRegistry()
        let anchor = DeskWindowAnchor.Anchor()
        anchor.registry = registry
        anchor.key = .display(7)
        anchor.reconcileBinding(sessionID: "screen-7") {
            registry.register(.display(7), owner: anchor.owner, sessionID: "screen-7")
        }
        var insideDismantle = false, synchronousPublications = 0, publications = 0
        let observation = registry.$entries.dropFirst().sink { _ in
            publications += 1
            if insideDismantle { synchronousPublications += 1 }
        }
        defer { observation.cancel() }

        insideDismantle = true
        DeskWindowAnchor.dismantleUIView(anchor, coordinator: ())
        insideDismantle = false

        XCTAssertEqual(synchronousPublications, 0,
                       "Representable dismantling must not publish observable state inside SwiftUI's view update.")
        try await Loopback.waitUntil { registry.entries[.display(7)] == nil }
        XCTAssertEqual(publications, 1, "The owner must still be released after dismantling.")
    }

    func testQueuedAnchorBindingAndDismantleCannotRemoveAReplacementOwner() async {
        let registry = DeskWindowRegistry()
        let anchor = DeskWindowAnchor.Anchor()
        anchor.registry = registry
        anchor.key = .display(7)
        anchor.reconcileBinding(sessionID: "screen-7") {
            registry.register(.display(7), owner: anchor.owner, sessionID: "screen-7")
        }
        anchor.bindAfterViewUpdate()
        DeskWindowAnchor.dismantleUIView(anchor, coordinator: ())
        let replacement = UUID()
        registry.register(.display(7), owner: replacement, sessionID: "screen-7")
        // Both the previously queued binding and deferred teardown get actor turns. Neither
        // may reclaim the dismantled anchor or unregister the new owner of this same key.
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(registry.entries[.display(7)]?.owner, replacement)
        XCTAssertEqual(registry.entries[.display(7)]?.sessionID, "screen-7")
        XCTAssertNil(anchor.registry)
        XCTAssertNil(anchor.boundRegistry)
        XCTAssertNil(anchor.boundKey)
    }

    func testNativeDisplayRequestsCreateSelectedScreensAndReuseAnExistingOne() async throws {
        let initial = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier))
        // XCTest repeats a method in the same app process. A synchronous defer that merely
        // requests destruction lets the next invocation reopen windows still being closed.
        // Register awaited cleanup before creating anything, including for a failed assertion.
        addTeardownBlock { @MainActor in
            try await self.destroyTestScenes(preserving: initial)
        }
        let ids: Set<UInt32> = [777, 778, 779, 780]
        // Reuse the same display IDs after a completed close in this test as well as across
        // XCTest iterations. This verifies the cleanup barrier against real scene lifecycle.
        for _ in 0..<2 {
            var failed = false
            for id in ids { DisplayWindowActivity.open(displayID: id) { failed = true } }
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            var found: [DeskWindowAnchor.Anchor] = []
            while !failed && ProcessInfo.processInfo.systemUptime < deadline {
                let newScenes = UIApplication.shared.connectedScenes.filter { !initial.contains($0.session.persistentIdentifier) }
                found = newScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                    .flatMap { anchors(in: $0) }.filter { anchor in
                        if case let .display(id) = anchor.boundKey { return ids.contains(id) }
                        return false
                    }
                if found.count == ids.count { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertFalse(failed, "Native scene activation must not reject the display requests.")
            XCTAssertEqual(found.count, ids.count, "Every requested screen must bind its own real native scene.")
            let foundIDs = Set(found.compactMap { anchor -> UInt32? in
                guard case let .display(id) = anchor.boundKey else { return nil }
                return id
            })
            XCTAssertEqual(foundIDs, ids, "The native scenes must represent every requested display exactly once.")
            let sceneIDs = Set(found.compactMap { $0.window?.windowScene?.session.persistentIdentifier })
            XCTAssertEqual(sceneIDs.count, ids.count, "Each requested display needs its own native scene.")
            // A failed creation is already reported. Reuse cannot be meaningfully checked
            // until all its prerequisite windows exist; teardown still runs on this return.
            guard !failed, found.count == ids.count, foundIDs == ids, sceneIDs.count == ids.count else { return }
            for anchor in found {
                let key = try XCTUnwrap(anchor.boundKey)
                XCTAssertEqual(anchor.boundRegistry?.entries[key]?.sessionID, anchor.window?.windowScene?.session.persistentIdentifier)
            }
            let before = Set(UIApplication.shared.connectedScenes.map { $0.session.persistentIdentifier })
            for id in ids { DisplayWindowActivity.open(displayID: id) { failed = true } }
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertFalse(failed)
            XCTAssertEqual(Set(UIApplication.shared.connectedScenes.map { $0.session.persistentIdentifier }), before,
                           "Reopening a selected screen must activate its existing scene rather than create a duplicate.")
            try await destroyTestScenes(preserving: initial)
        }
    }

    private func destroyTestScenes(preserving initial: Set<String>) async throws {
        let scenes = UIApplication.shared.connectedScenes.filter { !initial.contains($0.session.persistentIdentifier) }
        let sessions = UIApplication.shared.openSessions.filter { !initial.contains($0.persistentIdentifier) }
        let owned = Set(sessions.map(\.persistentIdentifier)).union(scenes.map { $0.session.persistentIdentifier })
        let registries = scenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .flatMap { anchors(in: $0) }.compactMap(\.boundRegistry)
        var failures: [String] = []
        for session in sessions {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
                failures.append(error.localizedDescription)
            }
        }
        try await Loopback.waitUntil(timeout: 10) {
            !failures.isEmpty || (
                UIApplication.shared.connectedScenes.allSatisfy { !owned.contains($0.session.persistentIdentifier) }
                && UIApplication.shared.openSessions.allSatisfy { !owned.contains($0.persistentIdentifier) }
                && registries.allSatisfy { registry in
                    registry.entries.values.allSatisfy { !owned.contains($0.sessionID) }
                }
            )
        }
        XCTAssertTrue(failures.isEmpty, "Native test-window cleanup failed: \(failures.joined(separator: "; "))")
        guard failures.isEmpty else { throw Loopback.WaitError.timeout }
    }

    private func anchors(in view: UIView) -> [DeskWindowAnchor.Anchor] {
        (view as? DeskWindowAnchor.Anchor).map { [$0] } ?? view.subviews.flatMap { anchors(in: $0) }
    }
}
