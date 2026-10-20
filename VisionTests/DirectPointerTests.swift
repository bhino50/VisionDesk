import CoreGraphics
import DeskCore
import Foundation
import XCTest
@testable import VisionDesk

@MainActor
final class DirectPointerTests: XCTestCase {
    private func pointer() -> (PointerInput, () -> [DeskMessage]) {
        let input = PointerInput()
        var messages: [DeskMessage] = []
        input.canControl = { _ in true }
        input.isLinked = { true }
        input.send = { messages.append($0); return true }
        return (input, { messages })
    }

    func testTrackpadRepositioningContinuesFromLastPointerWithoutWarping() {
        let (input, messages) = pointer()
        input.placePointer(displayID: 1, at: CGPoint(x: 0.8, y: 0.7))
        let token = UUID(), start = CGPoint(x: 0.2, y: 0.2)
        input.updateGesture(token: token, displayID: 1, mode: .pointer,
                            start: start, point: start, translation: .zero)
        XCTAssertEqual(messages().last?.x ?? -1, 0.8, accuracy: 0.000001)
        XCTAssertEqual(messages().last?.y ?? -1, 0.7, accuracy: 0.000001)
        input.finishGesture(token: token, displayID: 1, mode: .pointer,
                            start: start, point: CGPoint(x: 0.25, y: 0.3), translation: .zero)
        XCTAssertEqual(messages().last?.x ?? -1, 0.85, accuracy: 0.000001)
        XCTAssertEqual(messages().last?.y ?? -1, 0.8, accuracy: 0.000001)
        XCTAssertFalse(messages().contains { $0.action == "leftDown" || $0.action == "leftUp" })
    }

    func testTrackpadRelativeMovementClampsToDisplayEdges() {
        let (input, messages) = pointer()
        input.placePointer(displayID: 1, at: CGPoint(x: 0.95, y: 0.05))
        let token = UUID(), start = CGPoint(x: 0.4, y: 0.6)
        input.updateGesture(token: token, displayID: 1, mode: .pointer,
                            start: start, point: start, translation: .zero)
        input.finishGesture(token: token, displayID: 1, mode: .pointer,
                            start: start, point: CGPoint(x: 0.8, y: 0.2), translation: .zero)
        XCTAssertEqual(messages().last?.x, 1)
        XCTAssertEqual(messages().last?.y, 0)
    }

    func testFirstTapAimsAndClicksAndNextTapRetargets() {
        let (input, messages) = pointer()
        for point in [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.7)] {
            input.directTapClick(displayID: 1, at: point)
            let pressAndRelease = messages().filter { $0.action == "leftDown" || $0.action == "leftUp" }.suffix(2)
            XCTAssertEqual(pressAndRelease.map(\.action), ["leftDown", "leftUp"])
            XCTAssertTrue(pressAndRelease.allSatisfy { $0.x == Double(point.x) && $0.y == Double(point.y) })
            XCTAssertEqual(messages().last(where: { $0.action == "move" })?.x, Double(point.x))
        }
        XCTAssertNil(input.activeDisplayID)
    }

    func testInvalidAndRevokedTapsSendNothing() {
        let (input, messages) = pointer()
        for point in [CGPoint(x: -0.1, y: 0.5), CGPoint(x: .nan, y: 0.5), CGPoint(x: 0.5, y: 1.1)] {
            input.directTapClick(displayID: 1, at: point)
        }
        input.canControl = { _ in false }
        input.directTapClick(displayID: 1, at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(messages().isEmpty)
    }

    func testTapCannotStealAnyActiveGesture() {
        for mode in ScreenInteractionMode.allCases {
            let (input, messages) = pointer()
            let token = UUID(), point = CGPoint(x: 0.2, y: 0.3)
            input.updateGesture(token: token, displayID: 1, mode: mode,
                                start: point, point: point, translation: .zero)
            let count = messages().count
            input.directTapClick(displayID: 1, at: point)
            input.directTapClick(displayID: 2, at: point)
            input.click(displayID: 1, action: "rightClick")
            input.click(displayID: 1, action: "doubleClick")
            input.placePointer(displayID: 1, at: CGPoint(x: 0.9, y: 0.9))
            XCTAssertEqual(messages().count, count)
            XCTAssertEqual(input.activeDisplayID, 1)
            input.cancelGesture(token: token)
        }
    }

    func testDirectDragCancellationReleasesEvenAfterControlExpires() {
        let (input, messages) = pointer()
        let token = UUID(), point = CGPoint(x: 0.2, y: 0.3)
        input.updateGesture(token: token, displayID: 1, mode: .direct,
                            start: point, point: point, translation: .zero)
        input.canControl = { _ in false }
        input.cancelGesture(token: token)
        input.cancelGesture(token: token)
        XCTAssertEqual(messages().filter { $0.action == "leftDown" }.count, 1)
        XCTAssertEqual(messages().filter { $0.action == "leftUp" }.count, 1)
        XCTAssertNil(input.activeDisplayID)
    }

    func testDirectDragReleasesOnceAndLateCallbacksCannotPressAgain() {
        let (input, messages) = pointer()
        let token = UUID(), point = CGPoint(x: 0.2, y: 0.3)
        input.updateGesture(token: token, displayID: 1, mode: .direct,
                            start: point, point: point, translation: .zero)
        input.finishGesture(token: token, displayID: 1, mode: .direct,
                            start: point, point: point, translation: .zero)
        input.finishGesture(token: token, displayID: 1, mode: .direct,
                            start: point, point: point, translation: .zero)
        input.updateGesture(token: token, displayID: 1, mode: .direct,
                            start: point, point: point, translation: .zero)
        XCTAssertEqual(messages().filter { $0.action == "leftDown" }.count, 1)
        XCTAssertEqual(messages().filter { $0.action == "leftUp" }.count, 1)
        XCTAssertNil(input.activeDisplayID)
        XCTAssertTrue(ScreenGesturePolicy.tapClicks(in: .direct))
        XCTAssertGreaterThan(ScreenGesturePolicy.panMinimumDistance(for: .direct), 0)
    }
}
