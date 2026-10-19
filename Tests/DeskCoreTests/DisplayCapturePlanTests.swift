import XCTest
@testable import DeskCore

final class DisplayCapturePlanTests: XCTestCase {
    private func display(_ id: UInt32) -> DisplayInfo {
        DisplayInfo(id: id, name: "Screen \(id)", width: 1920, height: 1080,
                    originX: Double(id) * 1920, originY: 0, pointWidth: 1920, pointHeight: 1080)
    }

    func testFourScreensReadyRegardlessOfCaptureOrder() throws {
        try DisplayCapturePlan.validate(inventory: (1...4).map { display(UInt32($0)) }, capturableIDs: [4, 2, 1, 3])
    }

    func testPartialDockInventoryReportsEveryMissingSource() {
        let inventory = (1...4).map { display(UInt32($0)) }
        XCTAssertThrowsError(try DisplayCapturePlan.validate(inventory: inventory, capturableIDs: [1, 3, 99])) { error in
            let missing = error as? DisplayCapturePlan.Unavailable
            XCTAssertEqual(missing?.displays.map(\.id), [2, 4])
            XCTAssertTrue(error.localizedDescription.contains("Screen 2"))
            XCTAssertTrue(error.localizedDescription.contains("Screen 4"))
        }
        // A later dock-ready snapshot succeeds using exactly the same physical inventory.
        XCTAssertNoThrow(try DisplayCapturePlan.validate(inventory: inventory, capturableIDs: [1, 2, 3, 4]))
    }

    func testDisconnectLeavesRemainingSourcesShareable() throws {
        try DisplayCapturePlan.validate(inventory: [display(1)], capturableIDs: [1])
    }

    func testEmptyArrangementDoesNotStartAListenerWithoutScreens() {
        XCTAssertThrowsError(try DisplayCapturePlan.validate(inventory: [], capturableIDs: []))
    }

    func testFifthScreenDoesNotBlockTheFirstFour() {
        let selected = DisplayCapturePlan.select(inventory: (1...5).map { display(UInt32($0)) })
        XCTAssertEqual(selected.map(\.id), [1, 2, 3, 4])
        XCTAssertNoThrow(try DisplayCapturePlan.validate(inventory: selected, capturableIDs: [1, 2, 3, 4]))
    }

    func testExplicitSelectionDoesNotSubstituteAnUnselectedDisplay() {
        let inventory = (1...5).map { display(UInt32($0)) }
        XCTAssertEqual(DisplayCapturePlan.select(inventory: inventory, preferredIDs: [1, 3, 5]).map(\.id), [1, 3, 5])
        XCTAssertEqual(DisplayCapturePlan.select(inventory: [display(2)], preferredIDs: [1, 3, 5]), [])
        XCTAssertEqual(DisplayCapturePlan.select(inventory: inventory, preferredIDs: [1, 2, 3, 4, 5]).count, 4)
    }

    func testDuplicateSourcesNeverConsumeSelectionSlots() {
        XCTAssertEqual(DisplayCapturePlan.select(inventory: [display(1), display(1), display(2)]).map(\.id), [1, 2])
    }

    func testPhysicalIdentityResolvesAfterRuntimeIDChanges() {
        XCTAssertEqual(DisplayCapturePlan.resolve(identities: ["screen-a"], current: [9: "screen-a", 1: "screen-b"]), [9])
        XCTAssertEqual(DisplayCapturePlan.resolve(identities: ["screen-a"], current: [1: "screen-b"]), [])
        XCTAssertEqual(DisplayCapturePlan.resolve(identities: ["screen-a"], current: [1: "screen-a", 9: "screen-a"]), [])
    }
}
