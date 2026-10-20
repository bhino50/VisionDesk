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

    func testNativeDisplayRequestsCreateSelectedScreensAndReuseAnExistingOne() async throws {
        let initial = Set(UIApplication.shared.connectedScenes.map { $0.session.persistentIdentifier })
        let ids: Set<UInt32> = [777, 778, 779, 780]
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
        defer {
            for scene in UIApplication.shared.connectedScenes where !initial.contains(scene.session.persistentIdentifier) {
                UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
            }
        }
        XCTAssertFalse(failed, "Native scene activation must not reject the display requests.")
        XCTAssertEqual(found.count, ids.count, "Every requested screen must bind its own real native scene.")
        for anchor in found {
            let key = try XCTUnwrap(anchor.boundKey)
            XCTAssertEqual(anchor.boundRegistry?.entries[key]?.sessionID, anchor.window?.windowScene?.session.persistentIdentifier)
        }
        let before = Set(UIApplication.shared.connectedScenes.map { $0.session.persistentIdentifier })
        DisplayWindowActivity.open(displayID: 777) { failed = true }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(failed)
        XCTAssertEqual(Set(UIApplication.shared.connectedScenes.map { $0.session.persistentIdentifier }), before,
                       "Reopening a selected screen must activate its existing scene rather than create a duplicate.")
    }

    private func anchors(in view: UIView) -> [DeskWindowAnchor.Anchor] {
        (view as? DeskWindowAnchor.Anchor).map { [$0] } ?? view.subviews.flatMap { anchors(in: $0) }
    }
}
