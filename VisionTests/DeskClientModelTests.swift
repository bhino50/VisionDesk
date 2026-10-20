import DeskCore
import Foundation
import Network
import Security
import SwiftUI
import XCTest
@testable import DeskTransport
@testable import VisionDesk

/// Client regression tests for the production `DeskClientModel`, the production UIKit frame
/// decoder in `DisplayStream`, and an authenticated `DeskTransport` loopback session.
///
/// Every gate is reached the way the app reaches it: a real scene phase, a real TLS handshake,
/// a real status grant from the mock Mac and a real decoded JPEG. No state is injected and no
/// production bypass exists. These checks prove client behavior in the simulator; they do not
/// prove physical Vision Pro hand-gesture input.
@MainActor
final class DeskClientModelTests: XCTestCase {
    func testDiscreteActionsDrainFastScrollBeforeTheirMessage() async throws {
        for action in ["text", "key"] {
            let session = try await controllableSession()
            defer { session.close() }
            let token = UUID(), point = CGPoint(x: 0.5, y: 0.5)
            session.model.updateGesture(token: token, displayID: 1, mode: .scroll,
                                        start: point, point: point, translation: .zero)
            for step in 1...100 {
                session.model.updateGesture(token: token, displayID: 1, mode: .scroll,
                                            start: point, point: point,
                                            translation: CGSize(width: 0, height: step * 10))
            }
            switch action {
            case "text": XCTAssertTrue(session.model.sendText("probe", displayID: 1))
            case "key": session.model.sendKey("return", displayID: 1)
            default: session.model.click(displayID: 1, action: action)
            }
            try await waitUntil { session.mac.actions.contains(action) }
            try await settle()
            let inputs = session.mac.received.filter { $0.kind == "input" }
            let index = try XCTUnwrap(inputs.firstIndex { $0.action == action })
            let distance = inputs[..<index].filter { $0.action == "scroll" }.compactMap(\.deltaY).reduce(0, +)
            XCTAssertEqual(distance, -1_400, accuracy: 1e-6, "\(action) must follow all owed scroll distance.")
            XCTAssertFalse(inputs[(index + 1)...].contains { $0.action == "scroll" }, "No scroll tail may follow a discrete action.")
        }
    }

    func testEndingFastScrollDrainsAllBoundedDistanceBeforeRelease() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let token = UUID(), point = CGPoint(x: 0.5, y: 0.5)
        session.model.updateGesture(token: token, displayID: 1, mode: .scroll,
                                    start: point, point: point, translation: .zero)
        // All callbacks run in one actor turn, so the scheduled flush cannot drain
        // the accumulation before the user finishes. Each delta is below the wire cap.
        for step in 1...100 {
            session.model.updateGesture(token: token, displayID: 1, mode: .scroll,
                                        start: point, point: point,
                                        translation: CGSize(width: 0, height: step * 10))
        }
        session.model.endGesture(token: token)
        try await waitUntil { session.mac.actions.contains("scroll") }
        try await settle()
        let scrolls = session.mac.received.filter { $0.action == "scroll" }
        XCTAssertEqual(scrolls.compactMap(\.deltaY).reduce(0, +), -1_400, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(scrolls.count, 5, "The bounded distance drains without replaying callbacks.")
        let delivered = scrolls.count
        try await settle()
        XCTAssertEqual(session.mac.received.filter { $0.action == "scroll" }.count, delivered)
    }

    func testPointerMovementNeverHoldsAButtonOrSelectsText() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let token = UUID(), start = CGPoint(x: 0.2, y: 0.3)
        session.model.updateGesture(token: token, displayID: 1, mode: .pointer,
                                   start: start, point: start, translation: .zero)
        session.model.finishGesture(token: token, displayID: 1, mode: .pointer,
                                    start: start, point: CGPoint(x: 0.8, y: 0.7),
                                    translation: CGSize(width: 100, height: 50))
        try await settle()
        let inputs = session.mac.received.filter { $0.kind == "input" }
        XCTAssertEqual(Set(inputs.compactMap(\.action)), ["move"])
        XCTAssertEqual(try XCTUnwrap(inputs.last?.x), 0.8, accuracy: 1e-9)
        XCTAssertFalse(session.mac.buttonHeld)
    }

    /// A Pointer pinch only points. Its click is the surface's native tap, so a pan that barely
    /// moved — the jitter of a hand held still — presses nothing, and neither does a completion
    /// that arrives with no changed callback before it. Were the pan to click as well as the
    /// tap, one pinch would reach the Mac as two clicks.
    func testAStationaryPointerPanMovesButNeverClicks() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let token = UUID(), point = CGPoint(x: 0.45, y: 0.6)
        session.model.updateGesture(token: token, displayID: 1, mode: .pointer,
                                   start: point, point: point, translation: .zero)
        session.model.updateGesture(token: token, displayID: 1, mode: .pointer,
                                    start: point, point: CGPoint(x: 0.452, y: 0.601),
                                    translation: CGSize(width: 3, height: 2))
        session.model.endGesture(token: token)
        session.model.finishGesture(token: UUID(), displayID: 1, mode: .pointer,
                                    start: point, point: point, translation: .zero)
        try await settle()
        XCTAssertEqual(session.mac.actions, ["move", "move"],
                       "A Pointer pan only moves, and a completion with no changed callback sends nothing.")
        XCTAssertFalse(session.mac.buttonHeld)
    }

    func testPointerThatMovesAwayAndBackCannotBecomeAnAccidentalClick() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let token = UUID(), start = CGPoint(x: 0.3, y: 0.4)
        session.model.updateGesture(token: token, displayID: 1, mode: .pointer,
                                   start: start, point: CGPoint(x: 0.7, y: 0.4),
                                   translation: CGSize(width: 80, height: 0))
        session.model.finishGesture(token: token, displayID: 1, mode: .pointer,
                                    start: start, point: start, translation: .zero)
        try await settle()
        XCTAssertFalse(session.mac.actions.contains("leftDown"))
        XCTAssertFalse(session.mac.actions.contains("scroll"))
        XCTAssertFalse(session.mac.buttonHeld)
    }

    func testCancelledStationaryPointerDoesNotClick() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let token = UUID(), point = CGPoint(x: 0.3, y: 0.4)
        session.model.updateGesture(token: token, displayID: 1, mode: .pointer,
                                   start: point, point: point, translation: .zero)
        session.model.cancelGesture(token: token)
        session.model.endGesture(token: token)
        try await settle()
        XCTAssertEqual(session.mac.actions, ["move"])
        XCTAssertFalse(session.mac.buttonHeld)
    }

    // MARK: Pointer tap

    /// The native tap is the Pointer click, and it presses where the pointer already is, never
    /// where the tap landed: in a headset that is wherever the wearer happened to look, and
    /// clicking there would move the pointer first. With nothing pointed yet there is no such
    /// place, so the tap is refused rather than aimed at a guess — the old centre fallback moved
    /// the pointer to click. Once pointing has sent a position, every tap clicks there however
    /// far away, or however jittery, the taps land. Each tap is one complete click and needs no pan.
    func testRepeatedTapsAtAWanderingGazeAllClickAtTheExistingPointer() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        model.tapClick(displayID: 1, at: CGPoint(x: 0.05, y: 0.9))
        try await settle()
        XCTAssertEqual(mac.actions, [], "Nothing had pointed yet, so there was nowhere to click without moving the pointer.")

        let pointer = CGPoint(x: 0.3, y: 0.6), pan = UUID()
        model.updateGesture(token: pan, displayID: 1, mode: .pointer,
                            start: pointer, point: pointer, translation: .zero)
        model.endGesture(token: pan)
        try await waitUntil { mac.actions.count == 1 }
        // Far-apart gazes, and the small wander of one gaze held on a target.
        let gazes = [CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.903, y: 0.098), CGPoint(x: 0.897, y: 0.104),
                     CGPoint(x: 0.05, y: 0.95), CGPoint(x: 0.95, y: 0.9)]
        for (index, gaze) in gazes.enumerated() {
            model.tapClick(displayID: 1, at: gaze)
            try await waitUntil { mac.actions.count == 1 + 3 * (index + 1) }
        }
        try await settle()

        XCTAssertEqual(Array(mac.actions.dropFirst(1)),
                       Array(repeating: ["move", "leftDown", "leftUp"], count: gazes.count).flatMap { $0 },
                       "Every tap is one complete click and nothing else.")
        let inputs = mac.received.filter { $0.kind == "input" }
        for message in inputs {
            XCTAssertEqual(try XCTUnwrap(message.x), pointer.x, accuracy: 1e-9, message.action ?? "")
            XCTAssertEqual(try XCTUnwrap(message.y), pointer.y, accuracy: 1e-9, message.action ?? "")
        }
        XCTAssertFalse(inputs.contains { message in
            gazes.contains { Double($0.x) == message.x && Double($0.y) == message.y }
        }, "No tapped location may reach the Mac, as a move or as a click.")
        XCTAssertFalse(mac.buttonHeld)
    }

    /// The surface lets a Pointer pan start only after its tap has failed, so one pinch is a click
    /// or a pan. Should a same-display pan still own the pointer when a tap arrives, the tap must
    /// not finish it: the position the pan was still holding back never reached the Mac, and
    /// draining it ahead of the press is exactly a click that moves the pointer. The tap cancels
    /// the pan, presses where the Mac's pointer was actually sent, and the pan's late change,
    /// completion, end, reset and cancel find a retired token with nothing left to send.
    func testATapDiscardsAnOverlappingPanUnsentMotionAndClicksWhereThePointerWasSent() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let pan = UUID(), sent = CGPoint(x: 0.25, y: 0.35), unsent = CGPoint(x: 0.6, y: 0.7)
        let gaze = CGPoint(x: 0.9, y: 0.1), travel = CGSize(width: 40, height: 40)
        // One actor turn, so `unsent` is still held back in the coalescer when the tap lands.
        model.updateGesture(token: pan, displayID: 1, mode: .pointer,
                            start: sent, point: sent, translation: .zero)
        model.updateGesture(token: pan, displayID: 1, mode: .pointer,
                            start: sent, point: unsent, translation: travel)
        model.tapClick(displayID: 1, at: gaze)
        model.updateGesture(token: pan, displayID: 1, mode: .pointer,
                            start: sent, point: CGPoint(x: 0.65, y: 0.75), translation: travel)
        model.finishGesture(token: pan, displayID: 1, mode: .pointer,
                            start: sent, point: unsent, translation: travel)
        model.endGesture(token: pan)
        model.gestureStateDidReset(token: pan)
        model.cancelGesture(token: pan)
        try await waitUntil { mac.actions.last == "leftUp" }
        try await settle()

        XCTAssertEqual(mac.actions, ["move", "move", "leftDown", "leftUp"],
                       "The pan's one sent move, then one click, and nothing after it.")
        for message in mac.received.filter({ $0.kind == "input" }) {
            XCTAssertEqual(try XCTUnwrap(message.x), sent.x, accuracy: 1e-9, message.action ?? "")
            XCTAssertEqual(try XCTUnwrap(message.y), sent.y, accuracy: 1e-9, message.action ?? "")
        }
        XCTAssertFalse(mac.buttonHeld)

        // Still retired once the recognizer has had time to report anything else.
        model.updateGesture(token: pan, displayID: 1, mode: .pointer,
                            start: sent, point: unsent, translation: travel)
        model.finishGesture(token: pan, displayID: 1, mode: .pointer,
                            start: sent, point: unsent, translation: travel)
        try await settle()
        XCTAssertEqual(mac.actions.count, 4, "A retired pan can never move the pointer again.")
    }

    /// Whatever order a lingering Pointer pan's completion, its recognizer reset and a tap arrive
    /// in, the Mac sees one press and one release where the pointer was actually sent, and
    /// nothing afterwards. A pan that completed before the tap sent its held-back position, so
    /// the pointer is there; a tap that arrived while the pan still owned the pointer cancelled
    /// it, so that position never went out. The tapped location never does.
    func testOnePinchYieldsExactlyOneClickAtTheSentPointerInEveryCallbackOrder() async throws {
        enum Order: CaseIterable { case tapFirst, panEndFirst, resetThenTap, resetSettlesThenTap }
        let start = CGPoint(x: 0.2, y: 0.3), held = CGPoint(x: 0.4, y: 0.5)
        let tapped = CGPoint(x: 0.85, y: 0.15), travel = CGSize(width: 30, height: 30)
        for order in Order.allCases {
            let session = try await controllableSession()
            defer { session.close() }
            let model = session.model, mac = session.mac
            let pan = UUID()
            // One actor turn, so `held` is still waiting in the coalescer when the pinch ends.
            model.updateGesture(token: pan, displayID: 1, mode: .pointer,
                                start: start, point: start, translation: .zero)
            model.updateGesture(token: pan, displayID: 1, mode: .pointer,
                                start: start, point: held, translation: travel)
            func endPan() {
                model.finishGesture(token: pan, displayID: 1, mode: .pointer,
                                    start: start, point: held, translation: travel)
            }
            switch order {
            case .tapFirst:
                model.tapClick(displayID: 1, at: tapped)
                endPan()
                model.gestureStateDidReset(token: pan)
            case .panEndFirst:
                endPan()
                model.tapClick(displayID: 1, at: tapped)
                model.gestureStateDidReset(token: pan)
            case .resetThenTap:
                model.gestureStateDidReset(token: pan)
                model.tapClick(displayID: 1, at: tapped)
                endPan()
            case .resetSettlesThenTap:
                model.gestureStateDidReset(token: pan)
                // The settlement runs on the next turn of this actor, so the pan is cancelled
                // and its held position discarded before the tap arrives.
                try await settle()
                model.tapClick(displayID: 1, at: tapped)
                endPan()
            }
            try await waitUntil { mac.actions.last == "leftUp" }
            try await settle()

            // Only a pan that completed before the tap sent its held position, and the pointer
            // is then there. Every other order cancelled the pan where it was last sent.
            let completed = order == .panEndFirst
            let pointer = completed ? held : start
            let inputs = mac.received.filter { $0.kind == "input" }
            let expected: [String] = completed
                ? ["move", "move", "move", "leftDown", "leftUp"]
                : ["move", "move", "leftDown", "leftUp"]
            XCTAssertEqual(mac.actions, expected, "\(order)")
            for message in inputs.suffix(3) {
                XCTAssertEqual(try XCTUnwrap(message.x), pointer.x, accuracy: 1e-9, "\(order)")
                XCTAssertEqual(try XCTUnwrap(message.y), pointer.y, accuracy: 1e-9, "\(order)")
            }
            let heldArrived = inputs.contains { $0.x == Double(held.x) && $0.y == Double(held.y) }
            XCTAssertEqual(heldArrived, completed,
                           "\(order): a tap discards the unsent position of a pan it cancels.")
            XCTAssertFalse(inputs.contains { $0.x == Double(tapped.x) && $0.y == Double(tapped.y) },
                           "\(order): the tapped location never reaches the Mac.")
            XCTAssertFalse(mac.buttonHeld, "\(order)")
        }
    }

    /// The surface's gesture policy, checked on the values its real gesture is built from. A
    /// Pointer pinch must travel before it pans, so a quick pinch and the jitter of a hand held
    /// still while making one stay a tap; Drag and Scroll attach no tap and start on pinch-down.
    func testOnlyPointerTapsClickAndItsPanWaitsForTravel() {
        XCTAssertTrue(ScreenGesturePolicy.tapClicks(in: .pointer))
        XCTAssertGreaterThan(ScreenGesturePolicy.panMinimumDistance(for: .pointer), 0)
        for mode in [ScreenInteractionMode.interact, .scroll] {
            XCTAssertFalse(ScreenGesturePolicy.tapClicks(in: mode), "\(mode)")
            XCTAssertEqual(ScreenGesturePolicy.panMinimumDistance(for: mode), 0, "\(mode)")
        }
    }

    /// A tap may only cancel a Pointer pan, which holds no button. A Drag holding the button and
    /// a Scroll owing distance both keep the pointer: the tap is refused, the toolbar click is
    /// refused, and each gesture still ends exactly as it would have without them.
    func testATapNeverInterruptsAHeldDragOrScroll() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let drag = UUID(), start = CGPoint(x: 0.3, y: 0.3)
        model.updateGesture(token: drag, displayID: 1, mode: .interact,
                            start: start, point: start, translation: .zero)
        try await waitUntil { mac.buttonHeld }
        let held = mac.actions.count
        model.tapClick(displayID: 1, at: CGPoint(x: 0.7, y: 0.7))
        model.clickAtLastPointer(displayID: 1)
        try await settle()
        XCTAssertEqual(mac.actions.count, held, "Nothing may press or move under a held Drag.")
        XCTAssertTrue(mac.buttonHeld, "The Drag still owns its press.")
        model.endGesture(token: drag)
        try await waitUntil { mac.actions.last == "leftUp" }
        XCTAssertEqual(mac.actions.filter { $0 == "leftDown" }.count, 1)
        XCTAssertEqual(mac.actions.filter { $0 == "leftUp" }.count, 1)
        XCTAssertFalse(mac.buttonHeld)

        let scroll = UUID(), point = CGPoint(x: 0.5, y: 0.5)
        model.updateGesture(token: scroll, displayID: 1, mode: .scroll,
                            start: point, point: point, translation: .zero)
        model.updateGesture(token: scroll, displayID: 1, mode: .scroll,
                            start: point, point: point, translation: CGSize(width: 0, height: 40))
        model.tapClick(displayID: 1, at: CGPoint(x: 0.2, y: 0.8))
        model.endGesture(token: scroll)
        try await waitUntil { mac.actions.contains("scroll") }
        try await settle()
        XCTAssertEqual(mac.actions.filter { $0 == "leftDown" }.count, 1, "A tap during a Scroll is refused.")
        XCTAssertEqual(mac.received.filter { $0.action == "scroll" }.compactMap(\.deltaY).reduce(0, +),
                       -56, accuracy: 1e-6, "The Scroll keeps every point of distance it owed.")
        XCTAssertFalse(mac.received.contains { $0.kind == "input" && $0.x == 0.2 },
                       "The refused tap's position never reaches the Mac.")
        XCTAssertFalse(mac.buttonHeld)
    }

    /// The toolbar's Left click is the fallback for a pinch the system did not read as a tap: it
    /// clicks where pointing left the pointer, and pointing itself pressed nothing on the way.
    func testToolbarLeftClickLandsWherePointerPanningLeftThePointer() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let token = UUID(), start = CGPoint(x: 0.2, y: 0.25), pointed = CGPoint(x: 0.66, y: 0.44)
        model.updateGesture(token: token, displayID: 1, mode: .pointer,
                            start: start, point: start, translation: .zero)
        model.finishGesture(token: token, displayID: 1, mode: .pointer, start: start,
                            point: pointed, translation: CGSize(width: 90, height: 40))
        try await waitUntil { mac.actions.count == 2 }
        try await settle()
        XCTAssertEqual(mac.actions, ["move", "move"], "Pointing moves the pointer and presses nothing.")
        XCTAssertFalse(mac.buttonHeld)

        model.clickAtLastPointer(displayID: 1)
        try await waitUntil { mac.actions.last == "leftUp" }
        XCTAssertEqual(Array(mac.actions.suffix(3)), ["move", "leftDown", "leftUp"])
        for message in mac.received.filter({ $0.kind == "input" }).suffix(3) {
            XCTAssertEqual(try XCTUnwrap(message.x), pointed.x, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(message.y), pointed.y, accuracy: 1e-9)
        }
        XCTAssertFalse(mac.buttonHeld)
    }

    func testNavigationKeysUseTheProtocolAllowlistAndStillRespectControl() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        for key in ["left", "right", "up", "down", "space", "cmd+shift+z"] {
            session.model.sendKey(key, displayID: 1)
        }
        session.model.sendKey("unsupported-key", displayID: 1)
        try await settle()
        XCTAssertEqual(session.mac.received.filter { $0.action == "key" }.compactMap(\.text),
                       ["left", "right", "up", "down", "space", "cmd+shift+z"])
        session.model.stopControl()
        session.model.sendKey("return", displayID: 1)
        try await settle()
        XCTAssertFalse(session.mac.received.contains { $0.action == "key" && $0.text == "return" })
    }

    func testRapidDragBurstSendsLatestPositionWithoutReplayingIntermediateHistory() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let token = UUID(), start = CGPoint(x: 0.1, y: 0.2)
        session.model.updateGesture(token: token, displayID: 1, mode: .interact,
                                    start: start, point: start, translation: .zero)
        for step in 1...1_000 {
            let x = 0.1 + Double(step) * 0.0007
            session.model.updateGesture(token: token, displayID: 1, mode: .interact,
                                        start: start, point: CGPoint(x: x, y: 0.2),
                                        translation: CGSize(width: step, height: 0))
        }
        session.model.endGesture(token: token)
        try await waitUntil { session.mac.actions.last == "leftUp" }
        let inputs = session.mac.received.filter { $0.kind == "input" }
        XCTAssertLessThan(inputs.count, 20, "A callback burst cannot queue its entire movement history.")
        XCTAssertEqual(try XCTUnwrap(inputs.last?.x), 0.8, accuracy: 1e-9)
        XCTAssertEqual(session.mac.actions.filter { $0 == "leftDown" }.count, 1)
        XCTAssertEqual(session.mac.actions.filter { $0 == "leftUp" }.count, 1)
        let delivered = inputs.count
        try await settle()
        XCTAssertEqual(session.mac.received.filter { $0.kind == "input" }.count, delivered,
                       "No delayed movement follows release.")
    }

    func testFineScrollBurstPreservesTotalDistanceAndHasNoTailAfterEnd() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let token = UUID(), point = CGPoint(x: 0.4, y: 0.5)
        for step in 0...100 {
            session.model.updateGesture(token: token, displayID: 1, mode: .scroll,
                                        start: point, point: point,
                                        translation: CGSize(width: 0, height: Double(step) * 0.15))
        }
        session.model.endGesture(token: token)
        try await waitUntil { session.mac.actions.contains("scroll") }
        try await settle()
        let scrolls = session.mac.received.filter { $0.action == "scroll" }
        XCTAssertEqual(scrolls.reduce(0) { $0 + ($1.deltaY ?? 0) }, -21, accuracy: 1e-8)
        XCTAssertLessThan(scrolls.count, 20)
        XCTAssertFalse(session.mac.actions.contains("leftDown"))
        let count = session.mac.actions.count
        try await settle()
        XCTAssertEqual(session.mac.actions.count, count)
    }

    func testStopDiscardsHeldBackMovementRatherThanReplayingItBeforeRelease() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let token = UUID(), start = CGPoint(x: 0.2, y: 0.3)
        session.model.updateGesture(token: token, displayID: 1, mode: .interact,
                                    start: start, point: start, translation: .zero)
        for _ in 0..<100 {
            session.model.updateGesture(token: token, displayID: 1, mode: .interact,
                                        start: start, point: CGPoint(x: 0.9, y: 0.9), translation: .zero)
        }
        session.model.stopControl()
        try await waitUntil { session.mac.controlMessages.last?.kind == "stop" }
        XCTAssertEqual(session.mac.actions.last, "leftUp")
        XCTAssertFalse(session.mac.received.contains { $0.kind == "input" && $0.x == 0.9 },
                       "Stop discards input waiting for the next pacing window.")
        let count = session.mac.actions.count
        try await settle()
        XCTAssertEqual(session.mac.actions.count, count)
        XCTAssertFalse(session.mac.buttonHeld)
    }

    func testFinalDragPositionArrivesBeforeReleaseAndLateCallbacksCannotRepress() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let token = UUID(), start = CGPoint(x: 0.2, y: 0.3), end = CGPoint(x: 0.8, y: 0.7)
        session.model.updateGesture(token: token, displayID: 1, mode: .interact,
                                    start: start, point: start, translation: .zero)
        session.model.finishGesture(token: token, displayID: 1, mode: .interact,
                                    start: start, point: end, translation: CGSize(width: 40, height: 20))
        try await waitUntil { session.mac.actions.last == "leftUp" }
        XCTAssertEqual(Array(session.mac.actions.suffix(2)), ["move", "leftUp"])
        let finalInputs = session.mac.received.filter { $0.kind == "input" }.suffix(2)
        for message in finalInputs {
            XCTAssertEqual(try XCTUnwrap(message.x), end.x, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(message.y), end.y, accuracy: 1e-9)
        }
        let delivered = session.mac.actions.count
        session.model.updateGesture(token: token, displayID: 1, mode: .interact,
                                    start: start, point: start, translation: .zero)
        session.model.finishGesture(token: token, displayID: 1, mode: .interact,
                                    start: start, point: end, translation: .zero)
        try await settle()
        XCTAssertEqual(session.mac.actions.count, delivered, "An ended recognizer cannot press again.")
        XCTAssertFalse(session.mac.buttonHeld)
    }

    func testCancelledRecognizerCannotRestartAfterModeOrFocusChange() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let token = UUID(), point = CGPoint(x: 0.4, y: 0.5)
        session.model.updateGesture(token: token, displayID: 1, mode: .interact,
                                    start: point, point: point, translation: .zero)
        session.model.cancelGesture(token: token)
        try await waitUntil { session.mac.actions.last == "leftUp" }
        let delivered = session.mac.actions.count
        session.model.updateGesture(token: token, displayID: 1, mode: .interact,
                                    start: point, point: CGPoint(x: 0.9, y: 0.9), translation: .zero)
        try await settle()
        XCTAssertEqual(session.mac.actions.count, delivered)
        XCTAssertFalse(session.mac.buttonHeld)
        let fresh = UUID()
        session.model.updateGesture(token: fresh, displayID: 1, mode: .interact,
                                    start: point, point: point, translation: .zero)
        session.model.endGesture(token: fresh)
        try await waitUntil { session.mac.actions.count > delivered }
        try await settle()
        XCTAssertEqual(session.mac.actions.filter { $0 == "leftDown" }.count, 2,
                       "A new pinch still works after the old one was cancelled.")
    }

    // MARK: Recognizer-reset ordering

    /// SwiftUI resets a gesture's recognizer state for a completion and a cancellation alike,
    /// and does not order that reset against the completion callback. Observed first — the
    /// order this test drives — treating the reset as a cancellation would discard everything
    /// the finished gesture still owed, which is precisely the distance the drain exists to
    /// deliver. Both calls run in one actor turn, as the surface makes them.
    func testACompletedGestureStillDrainsWhenItsRecognizerResetIsObservedFirst() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let token = UUID(), point = CGPoint(x: 0.5, y: 0.5)
        session.model.updateGesture(token: token, displayID: 1, mode: .scroll,
                                    start: point, point: point, translation: .zero)
        for step in 1...100 {
            session.model.updateGesture(token: token, displayID: 1, mode: .scroll,
                                        start: point, point: point,
                                        translation: CGSize(width: 0, height: step * 10))
        }
        session.model.gestureStateDidReset(token: token)
        session.model.endGesture(token: token)

        try await waitUntil { session.mac.actions.contains("scroll") }
        try await settle()
        let scrolls = session.mac.received.filter { $0.action == "scroll" }
        XCTAssertEqual(scrolls.compactMap(\.deltaY).reduce(0, +), -1_400, accuracy: 1e-6,
                       "A reset seen before the completion may not discard what the gesture owed.")
        let delivered = session.mac.actions.count
        try await settle()
        XCTAssertEqual(session.mac.actions.count, delivered, "No scroll tail may follow the release.")
    }

    /// The other half of the same contract: a reset that no completion follows is a real
    /// cancellation, so the held position is dropped rather than delivered and the button
    /// still comes up. The settlement runs on the next turn of this actor, which is well
    /// inside the coalescing window the held movement is waiting on.
    func testARecognizerResetWithNoCompletionCancelsAndDiscardsWhatTheGestureHeld() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let token = UUID(), start = CGPoint(x: 0.2, y: 0.3)
        model.updateGesture(token: token, displayID: 1, mode: .interact,
                            start: start, point: start, translation: .zero)
        try await waitUntil { mac.buttonHeld }
        for step in 1...24 {
            model.updateGesture(token: token, displayID: 1, mode: .interact, start: start,
                                point: CGPoint(x: 0.9, y: 0.9),
                                translation: CGSize(width: Double(step) * 20, height: 0))
        }
        model.gestureStateDidReset(token: token)

        try await waitUntil { mac.actions.last == "leftUp" }
        let delivered = mac.actions.count
        try await settle()
        XCTAssertEqual(mac.actions.count, delivered)
        XCTAssertFalse(mac.received.contains { $0.kind == "input" && $0.x == 0.9 },
                       "A position held back before a cancellation must never arrive after it.")
        XCTAssertFalse(mac.buttonHeld)
        // The recognizer is retired either way, so a late callback cannot press again.
        model.updateGesture(token: token, displayID: 1, mode: .interact,
                            start: start, point: start, translation: .zero)
        try await settle()
        XCTAssertEqual(mac.actions.filter { $0 == "leftDown" }.count, 1)
    }

    /// The reverse order, which is the one the surface is written for: the completion settles
    /// the gesture and the reset that follows finds nothing left to cancel. One press, one
    /// release, and no second teardown.
    func testACompletionFollowedByItsRecognizerResetReleasesExactlyOnce() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let token = UUID(), start = CGPoint(x: 0.3, y: 0.4)
        model.updateGesture(token: token, displayID: 1, mode: .interact,
                            start: start, point: start, translation: .zero)
        model.endGesture(token: token)
        try await waitUntil { mac.actions.last == "leftUp" }
        let delivered = mac.actions.count

        model.gestureStateDidReset(token: token)
        try await settle()
        XCTAssertEqual(mac.actions.count, delivered, "A settled gesture has nothing left to cancel.")
        XCTAssertEqual(mac.actions.filter { $0 == "leftUp" }.count, 1)
        XCTAssertFalse(mac.buttonHeld)
    }

    // MARK: Cross-display arbitration

    /// One Mac pointer cannot be in two drags, and it cannot change what a drag means
    /// mid-gesture. Both would interleave as a press/release storm across two screens, so a
    /// recognizer that reports against another display — or in the other mode — is ignored
    /// rather than followed, and the drag it was already serving is left intact.
    func testADragCannotMigrateToAnotherDisplayOrModeMidGesture() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let second = DisplayInfo(id: 2, name: "Second Display", width: 1_920, height: 1_080,
                                 originX: 1_920, originY: 0, pointWidth: 1_920, pointHeight: 1_080)
        XCTAssertTrue(mac.publish(displays: [DeskFixtures.display, second]))
        try await waitUntil { model.displays.count == 2 }
        XCTAssertTrue(mac.sendFrame(session.frame, displayID: 2))
        try await waitUntil { model.canControl(displayID: 1) && model.canControl(displayID: 2) }

        let token = UUID(), start = CGPoint(x: 0.2, y: 0.2)
        model.updateGesture(token: token, displayID: 1, mode: .interact,
                            start: start, point: start, translation: .zero)
        try await waitUntil { mac.actions.filter { $0 == "leftDown" }.count == 1 }
        let held = mac.actions.count

        model.updateGesture(token: token, displayID: 2, mode: .interact,
                            start: start, point: CGPoint(x: 0.9, y: 0.9), translation: .zero)
        model.updateGesture(token: token, displayID: 1, mode: .scroll,
                            start: start, point: start, translation: CGSize(width: 0, height: 400))
        try await settle()
        XCTAssertEqual(mac.actions.count, held, "A drag may not migrate display or mode.")
        XCTAssertFalse(mac.actions.contains("scroll"), "A drag may not become a scroll under way.")

        model.endGesture(token: token)
        try await waitUntil { mac.actions.last == "leftUp" }
        XCTAssertEqual(mac.actions.filter { $0 == "leftDown" }.count, 1)
        XCTAssertEqual(mac.actions.filter { $0 == "leftUp" }.count, 1)
        XCTAssertFalse(mac.controlMessages.contains { $0.kind == "input" && $0.displayID == 2 },
                       "Nothing attributed to the ignored display may reach the Mac.")
        XCTAssertFalse(mac.buttonHeld)
        // The other display was never taken hostage by the first drag.
        pinch(model, displayID: 2, at: CGPoint(x: 0.4, y: 0.6))
        try await waitUntil { mac.controlMessages.contains { $0.kind == "input" && $0.displayID == 2 } }
        XCTAssertEqual(mac.actions.filter { $0 == "leftDown" }.count, 2)
    }

    // MARK: Assistive activation

    /// A hand clicks by pinching, and an assistive activation has no hand position, so the
    /// primary action clicks where this display was last pointed — the same position the
    /// right- and double-click actions use. Without it there is no reachable left click at all
    /// for someone driving the surface through accessibility.
    func testTheAssistivePrimaryClickLandsWhereTheDisplayWasLastPointed() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let pointed = CGPoint(x: 0.7, y: 0.3)
        pinch(model, displayID: 1, at: pointed)
        try await waitUntil { mac.actions.last == "leftUp" }
        let before = mac.actions.count

        model.clickAtLastPointer(displayID: 1)
        try await waitUntil { mac.actions.count == before + 3 }
        XCTAssertEqual(Array(mac.actions.suffix(3)), ["move", "leftDown", "leftUp"])
        for message in mac.received.filter({ $0.kind == "input" }).suffix(3) {
            XCTAssertEqual(try XCTUnwrap(message.x), pointed.x, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(message.y), pointed.y, accuracy: 1e-9)
        }
        XCTAssertFalse(mac.buttonHeld, "The press is matched by its own release.")

        // It is gated exactly like every other action, by the same per-display grant.
        model.stopControl()
        try await waitUntil { mac.controlMessages.last?.kind == "stop" }
        let gated = mac.actions.count
        model.clickAtLastPointer(displayID: 1)
        model.clickAtLastPointer(displayID: 99)
        model.tapClick(displayID: 1, at: CGPoint(x: 0.5, y: 0.5))
        try await settle()
        XCTAssertEqual(mac.actions.count, gated, "A revoked grant refuses the assistive and tapped clicks too.")
    }

    /// Discarding a removed display's stream demands a keyframe, and there is no display left
    /// to send one for. The request would be pointless on its own, and a request that failed
    /// to send would tear the session down from inside the removal — after the gesture
    /// release has already passed its `isLinked` check — leaving the stream list that is
    /// rebuilt immediately afterwards attached to a session that no longer exists.
    func testARemovedDisplayAsksForNoKeyframeOnItsWayOut() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let removed = DisplayInfo(id: 4, name: "Removed", width: 1_920, height: 1_080,
                                  originX: 1_920, originY: 0, pointWidth: 1_920, pointHeight: 1_080)
        XCTAssertTrue(mac.publish(displays: [DeskFixtures.display, removed]))
        try await waitUntil { model.displays.count == 2 }
        XCTAssertTrue(mac.sendFrame(session.frame, displayID: 4))
        try await waitUntil { model.canControl(displayID: 4) }
        let discarded = try XCTUnwrap(model.display(id: 4))
        // Every message the Mac received, not just the ones it classifies as control, so a
        // request that is never counted cannot make this pass by accident.
        func keyframeRequests(for id: UInt32) -> Int {
            mac.received.filter { $0.kind == "keyframe" && $0.displayID == id }.count
        }
        let before = keyframeRequests(for: 4)

        XCTAssertTrue(mac.publish(displays: [DeskFixtures.display]))
        try await waitUntil { model.displays.count == 1 }
        try await settle()

        XCTAssertEqual(keyframeRequests(for: 4), before,
                       "a stream being discarded has nothing to ask the Mac for")
        XCTAssertNil(discarded.image, "the removed stream is still cleared")
        XCTAssertNil(model.display(id: 4))
        XCTAssertTrue(model.isLinked, "removing one display does not end the session")
        XCTAssertTrue(model.canControl(displayID: 1), "the surviving display is unaffected")
    }

    func testReaddedDisplayGetsItsOwnImmediateRecoveryRequest() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let info = DisplayInfo(id: 4, name: "Reconnected display", width: 1920, height: 1080,
                               originX: 1920, originY: 0, pointWidth: 1920, pointHeight: 1080)
        model.receive(DeskMessage(kind: "displays", displays: [DeskFixtures.display, info]))
        let old = try XCTUnwrap(model.display(id: 4))
        let baseline = mac.received.filter { $0.kind == "keyframe" && $0.displayID == 4 }.count
        old.onKeyframeNeeded?()
        // Removing and replacing a stream is synchronous here, so the old stream's
        // half-second rate limit cannot accidentally expire before the assertion.
        model.receive(DeskMessage(kind: "displays", displays: [DeskFixtures.display]))
        XCTAssertNil(old.onKeyframeNeeded)
        model.receive(DeskMessage(kind: "displays", displays: [DeskFixtures.display, info]))
        let replacement = try XCTUnwrap(model.display(id: 4))
        replacement.onKeyframeNeeded?()
        try await waitUntil {
            mac.received.filter { $0.kind == "keyframe" && $0.displayID == 4 }.count == baseline + 2
        }
    }

    // MARK: A release the channel refuses

    /// The release at the end of a drag can fail. `DeskConnection` fails a control send closed
    /// rather than queueing input behind video, so a channel whose send queue has filled
    /// refuses the `leftUp` and ends the session on the spot — reentrantly, inside the very
    /// call the model made to send it.
    ///
    /// That is the ordering the display-removal path has to survive. `receive` releases the
    /// gesture belonging to a display that has gone away and then rebuilds the stream list; if
    /// the release tore the session down underneath it, the list it is about to rebuild belongs
    /// to a session that no longer exists. The `guard isLinked` after the release is what stops
    /// that, and this is what reaches it.
    ///
    /// Nothing is faked. The channel is a real `DeskConnection` over the same PSK-TLS
    /// handshake every other test here uses, authenticating against the same mock Mac; the
    /// only injected thing is which connection object the model is handed, and the queue bound
    /// it was built with. The gesture, the grant, the frames and the removal are all real.
    func testAReleaseRefusedByTheChannelTearsDownWithoutResurrectingTheDisplays() async throws {
        let mac = MockMac()
        var captured: DeskConnection?
        let model = DeskClientModel(keys: Self.store(MemoryKeychain()), preferences: MemoryRememberedMacStore()) { endpoint, key in
            let channel = DeskConnection(
                connection: NWConnection(to: endpoint, using: SecureParameters.make(key: key)),
                idleTimeout: nil, maximumPendingBytes: Loopback.constrainedQueueBytes
            )
            captured = channel
            return channel
        }
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        model.updateScene(scene, phase: .active)
        try mac.start()
        try await waitUntil { mac.endpoint != nil }
        model.connect(to: try XCTUnwrap(mac.endpoint), key: mac.key, name: "Loopback Mac")
        try await waitUntil(timeout: 15) { model.isLinked && mac.isConnected }

        // Two live displays, so the removal leaves something the model would otherwise rebuild.
        let removed = DisplayInfo(id: 4, name: "Removed", width: 1_920, height: 1_080,
                                  originX: 1_920, originY: 0, pointWidth: 1_920, pointHeight: 1_080)
        XCTAssertTrue(mac.publish(displays: [DeskFixtures.display, removed]))
        try await waitUntil { model.displays.count == 2 }
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await waitUntil { model.isMacControlEnabled }
        let frame = try XCTUnwrap(DeskFixtures.jpeg(), "The platform could not encode a JPEG fixture.")
        for id in [UInt32(1), UInt32(4)] { XCTAssertTrue(mac.sendFrame(frame, displayID: id)) }
        try await waitUntil { model.canControl(displayID: 1) && model.canControl(displayID: 4) }

        let pointed = CGPoint(x: 0.3, y: 0.7)
        model.updateGesture(token: UUID(), displayID: 4, mode: .interact,
                            start: pointed, point: pointed, translation: .zero)
        try await waitUntil { mac.buttonHeld }
        let channel = try XCTUnwrap(captured, "the model has to use the channel it was given")

        // No suspension from here on: `.contentProcessed` completions run on this actor, so
        // not yielding is what keeps the queue full while the release is attempted.
        let release = DeskMessage(kind: "input", displayID: 4,
                                  x: Double(pointed.x), y: Double(pointed.y), action: "leftUp")
        let releaseBytes = try FrameCodec.encode(release).count
        try Loopback.fillSendQueue(channel, leaving: releaseBytes - 1)
        XCTAssertEqual(channel.pendingBytes, Loopback.constrainedQueueBytes - (releaseBytes - 1),
                       "the queue has to end up exactly one byte short of carrying the release")
        XCTAssertTrue(model.isLinked, "filling the queue may not itself end the session")

        model.receive(DeskMessage(kind: "displays", displays: [DeskFixtures.display]))

        XCTAssertFalse(model.isLinked, "a refused control send fails the channel closed")
        XCTAssertTrue(model.displays.isEmpty,
                      "a release that tore the session down may not leave rebuilt streams behind")
        XCTAssertNil(model.display(id: 1))
        XCTAssertNil(model.display(id: 4))
        XCTAssertFalse(model.canControl)
        XCTAssertNotNil(model.connectionMessage, "the drop has to be reported, not silent")

        // The Mac could not be told to release, so losing the connection is what releases it.
        try await waitUntil { !mac.isConnected }
        XCTAssertFalse(mac.buttonHeld)
        XCTAssertGreaterThanOrEqual(mac.releaseCount, 1)
    }

    // MARK: Screen-source transitions

    /// A real session uses both sources: the Mac sends a cached JPEG for every display the
    /// moment a client attaches and only moves to H.264 once it knows the client's codec, and
    /// a display whose hardware encoder fails latches back to JPEG for good.
    ///
    /// So a decode belonging to the source being retired can still be in flight at the switch,
    /// and its older picture must not land on top of the newer source's answer — nor refresh
    /// the freshness stamp that decides whether this screen accepts input. The two `accept`
    /// calls below run in one actor turn, which is what makes the JPEG decode certainly still
    /// outstanding when the source changes under it.
    func testASourceSwitchKeepsTheNewestAcceptedPictureAuthoritative() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let stream = try XCTUnwrap(session.model.display(id: 1))
        XCTAssertFalse(stream.usesVideo)
        XCTAssertNotNil(stream.image)

        // The wire path first, so the transition under test is one the Mac can actually cause.
        XCTAssertTrue(session.mac.sendVideo(DeskFixtures.syntheticVideoKeyframe()))
        try await waitUntil { stream.usesVideo }

        stream.accept(jpeg: session.frame)
        stream.accept(video: DeskFixtures.syntheticVideoKeyframe(sequence: 1))
        XCTAssertTrue(stream.usesVideo, "The last source to be accepted owns the stream.")
        // VideoToolbox cannot build a session from synthetic parameter sets, so the video
        // pipeline's own answer is "no picture". The orphaned JPEG may not overrule it.
        try await waitUntil { stream.image == nil }
        try await settle()
        XCTAssertNil(stream.image, "A decode orphaned by a source switch may not publish after it.")
        XCTAssertFalse(stream.isFresh())
        XCTAssertFalse(session.model.canControl(displayID: 1))
        XCTAssertTrue(session.model.isLinked, "A failed source transition ends input, not viewing.")

        // The retired pipeline is still usable: the epoch bump cleared its task handle, so a
        // later JPEG is not refused forever by `guard decodeTask == nil`.
        stream.accept(jpeg: session.frame)
        try await waitUntil { stream.image != nil }
        XCTAssertFalse(stream.usesVideo)
        XCTAssertNil(stream.decodeWarning)
        try await waitUntil { session.model.canControl(displayID: 1) }
    }

    // MARK: Focus

    func testInactiveWindowGatesInputAndKeepsTheMacGrant() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        XCTAssertTrue(model.canControl(displayID: 1))

        model.updateScene(session.scene, phase: .inactive)
        XCTAssertFalse(model.hasActiveWindow)
        XCTAssertFalse(model.canControl)
        XCTAssertTrue(model.isMacControlEnabled, "A glance away must not discard the Mac's grant.")
        XCTAssertTrue(model.isLinked)

        let gated = mac.actions.count
        pinch(model, displayID: 1, at: CGPoint(x: 0.25, y: 0.75))
        model.updateGesture(
            token: UUID(), displayID: 1, mode: .interact,
            start: CGPoint(x: 0.25, y: 0.75), point: CGPoint(x: 0.3, y: 0.75), translation: .zero
        )
        model.sendKey("return", displayID: 1)
        model.tapClick(displayID: 1, at: CGPoint(x: 0.25, y: 0.75))
        model.clickAtLastPointer(displayID: 1)
        try await settle()
        XCTAssertEqual(mac.actions.count, gated, "No input may leave while no window is active.")

        model.updateScene(session.scene, phase: .active)
        XCTAssertTrue(model.canControl, "Control resumes without re-enabling anything on the Mac.")
        XCTAssertTrue(mac.sendFrame(session.frame))
        try await waitUntil { model.canControl(displayID: 1) }
        pinch(model, displayID: 1, at: CGPoint(x: 0.25, y: 0.75))
        try await waitUntil { mac.actions.count == gated + 3 }
        XCTAssertEqual(Array(mac.actions.suffix(3)), ["move", "leftDown", "leftUp"])
    }

    func testBackgroundSceneReleasesInputAndTearsDownTheSession() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let point = CGPoint(x: 0.6, y: 0.4)
        model.updateGesture(
            token: UUID(), displayID: 1, mode: .interact,
            start: point, point: point, translation: .zero
        )
        try await waitUntil { mac.actions.filter { $0 == "leftDown" }.count == 1 }

        model.updateScene(session.scene, phase: .background)
        try await waitUntil { !mac.isConnected }
        XCTAssertFalse(model.isLinked)
        XCTAssertFalse(model.isMacControlEnabled)
        XCTAssertFalse(model.canControl)
        XCTAssertTrue(model.displays.isEmpty)
        XCTAssertTrue(model.pairingCode.isEmpty)
        XCTAssertEqual(model.connectionMessage, "Connect again when you are ready.")
        // Immediate cancellation does not promise delivery of queued messages. The Mac
        // must release on disconnect; Stop's ordered delivery is tested on a live channel.
        XCTAssertFalse(mac.buttonHeld)
        XCTAssertGreaterThanOrEqual(mac.releaseCount, 1)

        let delivered = mac.actions.count
        pinch(model, displayID: 1, at: point)
        try await settle()
        XCTAssertEqual(mac.actions.count, delivered, "A torn-down session cannot send input.")
    }

    // MARK: Control grant

    func testStopSendsReleaseThenStopAndRequiresANewMacGrant() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let point = CGPoint(x: 0.4, y: 0.4)
        model.updateGesture(
            token: UUID(), displayID: 1, mode: .interact,
            start: point, point: point, translation: .zero
        )
        try await waitUntil { mac.actions.filter { $0 == "leftDown" }.count == 1 }

        model.stopControl()
        try await waitUntil { mac.controlMessages.last?.kind == "stop" }
        XCTAssertEqual(Array(mac.controlMessages.suffix(2)).map(\.kind), ["input", "stop"])
        XCTAssertEqual(mac.actions.last, "leftUp", "The held button is released before Stop.")
        XCTAssertFalse(model.canControl)
        XCTAssertFalse(model.isMacControlEnabled)
        XCTAssertTrue(model.isLinked, "Stop revokes input and leaves viewing available.")

        XCTAssertTrue(mac.publishStatus("repeated grant", controlEnabled: true))
        try await waitUntil { model.statusText == "repeated grant" }
        XCTAssertFalse(model.canControl, "A repeated grant is ignored until the Mac acknowledges.")
        XCTAssertFalse(model.isMacControlEnabled)

        // The companion's own `revoke` publishes controlEnabled false; an operator then
        // re-enables control, which is the only way back.
        XCTAssertTrue(mac.publishStatus("input stopped on this Mac", controlEnabled: false))
        XCTAssertTrue(mac.publishStatus("control enabled again", controlEnabled: true))
        try await waitUntil { model.canControl }
        XCTAssertTrue(model.isMacControlEnabled)
    }

    // MARK: Drag arbitration

    func testFirstDragTokenWinsAndEveryEndOrCancelSendsLeftUp() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let first = UUID(), second = UUID(), third = UUID()
        let start = CGPoint(x: 0.2, y: 0.2)

        model.updateGesture(
            token: first, displayID: 1, mode: .interact,
            start: start, point: start, translation: .zero
        )
        try await waitUntil { mac.actions.filter { $0 == "leftDown" }.count == 1 }
        let held = mac.actions.count

        let other = CGPoint(x: 0.8, y: 0.8)
        model.updateGesture(
            token: second, displayID: 1, mode: .interact,
            start: other, point: other, translation: .zero
        )
        model.cancelGesture(token: second)
        try await settle()
        XCTAssertEqual(mac.actions.count, held, "A second drag is ignored and cannot release the first.")

        model.updateGesture(
            token: first, displayID: 1, mode: .interact, start: start,
            point: CGPoint(x: 0.3, y: 0.2), translation: CGSize(width: 24, height: 0)
        )
        try await waitUntil { mac.actions.count == held + 1 }
        XCTAssertEqual(mac.actions.last, "move", "The winning drag keeps moving the pointer.")

        model.endGesture(token: first)
        try await waitUntil { mac.actions.last == "leftUp" }

        model.updateGesture(
            token: third, displayID: 1, mode: .interact,
            start: start, point: start, translation: .zero
        )
        try await waitUntil { mac.actions.filter { $0 == "leftDown" }.count == 2 }
        model.cancelGesture(token: third)
        try await waitUntil { mac.actions.filter { $0 == "leftUp" }.count == 2 }
        XCTAssertEqual(mac.actions.filter { $0 == "leftDown" }.count, 2)
        XCTAssertEqual(
            mac.actions.filter { $0 == "leftUp" }.count, 2,
            "Every press is matched by exactly one release."
        )
    }

    // MARK: Video freshness

    func testStaleVideoReleasesTheHeldDragAndBlocksNewInput() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let point = CGPoint(x: 0.5, y: 0.5)
        model.updateGesture(
            token: UUID(), displayID: 1, mode: .interact,
            start: point, point: point, translation: .zero
        )
        try await waitUntil { mac.actions.filter { $0 == "leftDown" }.count == 1 }

        // No further frames arrive, so the decoded image expires on the client's own schedule
        // and the heartbeat has to lift the button. The wait is bounded by that behavior, not
        // by a constant copied out of the model.
        try await waitUntil(timeout: 10) { mac.actions.last == "leftUp" }
        XCTAssertFalse(model.canControl(displayID: 1))
        XCTAssertTrue(model.canControl, "Stale video gates one display without discarding the grant.")
        XCTAssertTrue(model.isLinked)

        let released = mac.actions.count
        pinch(model, displayID: 1, at: point)
        model.updateGesture(
            token: UUID(), displayID: 1, mode: .interact,
            start: point, point: point, translation: .zero
        )
        model.tapClick(displayID: 1, at: point)
        try await settle()
        XCTAssertEqual(mac.actions.count, released, "Stale video blocks new input.")

        XCTAssertTrue(mac.sendFrame(session.frame))
        try await waitUntil { model.canControl(displayID: 1) }
        pinch(model, displayID: 1, at: point)
        try await waitUntil { mac.actions.count == released + 3 }
        XCTAssertEqual(Array(mac.actions.suffix(3)), ["move", "leftDown", "leftUp"])
    }

    func testUnsupportedFrameNeverBecomesFreshVideo() async throws {
        let session = try await controllableSession(sendFrame: false)
        defer { session.close() }
        let model = session.model, mac = session.mac
        let stream = try XCTUnwrap(model.display(id: 1))
        XCTAssertTrue(model.canControl, "The Mac grant is independent of video.")
        XCTAssertFalse(model.canControl(displayID: 1))

        XCTAssertTrue(mac.sendFrame(DeskFixtures.malformedJPEG))
        try await waitUntil { stream.decodeWarning != nil }
        XCTAssertNil(stream.image)
        XCTAssertFalse(stream.isFresh())
        XCTAssertFalse(model.canControl(displayID: 1))

        pinch(model, displayID: 1, at: CGPoint(x: 0.5, y: 0.5))
        try await settle()
        XCTAssertTrue(mac.actions.isEmpty, "An undecodable frame cannot enable input.")

        XCTAssertTrue(mac.sendFrame(session.frame))
        try await waitUntil { model.canControl(displayID: 1) }
        XCTAssertNotNil(stream.image)
        XCTAssertNil(stream.decodeWarning)
    }

    // MARK: Geometry

    func testResizedDisplayClearsTheOldFrameWhileRescalingKeepsIt() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let stream = try XCTUnwrap(model.display(id: 1))
        XCTAssertTrue(model.canControl(displayID: 1))

        XCTAssertTrue(mac.publish(displays: [DeskFixtures.rescaledDisplay]))
        try await waitUntil { stream.info.pointWidth == 960 }
        XCTAssertNotNil(stream.image, "A point-size change does not invalidate the pixel grid.")
        XCTAssertTrue(model.canControl(displayID: 1))

        XCTAssertTrue(mac.publish(displays: [DeskFixtures.resizedDisplay]))
        try await waitUntil { stream.info.width == 1_280 }
        XCTAssertTrue(stream === model.display(id: 1), "The same stream is updated, not replaced.")
        XCTAssertNil(stream.image, "A resized display drops the frame with the old aspect ratio.")
        XCTAssertFalse(stream.isFresh())
        XCTAssertFalse(model.canControl(displayID: 1))

        let delivered = mac.actions.count
        pinch(model, displayID: 1, at: CGPoint(x: 0.5, y: 0.5))
        try await settle()
        XCTAssertEqual(mac.actions.count, delivered, "Input waits for a frame that matches the new size.")

        XCTAssertTrue(mac.sendFrame(session.frame))
        try await waitUntil { model.canControl(displayID: 1) }
    }

    /// A resolution change in the middle of a drag. The picture on screen describes the old
    /// pixel grid, so it is dropped and this display stops accepting input — which is what
    /// lifts the held button, by way of the heartbeat that re-checks the per-display grant
    /// rather than a gesture callback that may never arrive. The outcome is bounded and
    /// signalled: viewing continues, the Mac's grant survives, and a frame matching the new
    /// size restores control. Nothing is left pressed on the Mac in the meantime.
    func testAResizeDuringADragLiftsTheHeldButtonAndRestoresControlOnAMatchingFrame() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let stream = try XCTUnwrap(model.display(id: 1))
        let token = UUID(), start = CGPoint(x: 0.2, y: 0.3)
        model.updateGesture(token: token, displayID: 1, mode: .interact,
                            start: start, point: start, translation: .zero)
        try await waitUntil { mac.buttonHeld }

        XCTAssertTrue(mac.publish(displays: [DeskFixtures.resizedDisplay]))
        try await waitUntil { stream.info.width == 1_280 }
        XCTAssertNil(stream.image, "A frame with the old aspect ratio cannot map a pointer.")
        XCTAssertFalse(model.canControl(displayID: 1))
        try await waitUntil { !mac.buttonHeld }
        XCTAssertTrue(model.isLinked, "A resize ends input for one screen, not the session.")
        XCTAssertTrue(model.canControl, "The Mac's grant survives a resolution change.")

        // The interrupted recognizer is retired, so a late callback cannot press again.
        let released = mac.actions.count
        model.updateGesture(token: token, displayID: 1, mode: .interact,
                            start: start, point: CGPoint(x: 0.6, y: 0.6), translation: .zero)
        try await settle()
        XCTAssertEqual(mac.actions.count, released)

        XCTAssertTrue(mac.sendFrame(session.frame))
        try await waitUntil { model.canControl(displayID: 1) }
        pinch(model, displayID: 1, at: CGPoint(x: 0.5, y: 0.5))
        try await waitUntil { mac.actions.last == "leftUp" }
        XCTAssertFalse(mac.buttonHeld)
    }

    // MARK: Session

    func testFourScreensDecodeIndependentlyAndRemovedScreenReleasesDrag() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let infos = (1...4).map { id in
            DisplayInfo(id: UInt32(id), name: "Display \(id)", width: 1920, height: 1080,
                        originX: Double(id - 1) * 1920, originY: 0, pointWidth: 1920, pointHeight: 1080)
        }
        XCTAssertTrue(mac.publish(displays: infos))
        try await waitUntil { model.displays.count == 4 }
        for id in UInt32(1)...UInt32(4) { XCTAssertTrue(mac.sendFrame(session.frame, displayID: id)) }
        try await waitUntil { model.displays.allSatisfy { model.canControl(displayID: $0.id) } }
        let removed = try XCTUnwrap(model.display(id: 4))
        let point = CGPoint(x: 0.3, y: 0.7)
        model.updateGesture(token: UUID(), displayID: 4, mode: .interact,
                            start: point, point: point, translation: .zero)
        try await waitUntil { mac.buttonHeld }
        XCTAssertTrue(mac.publish(displays: Array(infos.prefix(3))))
        try await waitUntil { model.displays.count == 3 && !mac.buttonHeld }
        XCTAssertNil(removed.image)
        XCTAssertFalse(model.canControl(displayID: 4))
        XCTAssertTrue(model.canControl(displayID: 1))
        let count = mac.actions.count
        pinch(model, displayID: 4, at: point)
        model.tapClick(displayID: 4, at: point)
        model.clickAtLastPointer(displayID: 4)
        try await settle()
        XCTAssertEqual(mac.actions.count, count)
    }

    func testScrollClicksUnicodeTextAndShortcutsReachAuthenticatedMac() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let token = UUID(), point = CGPoint(x: 0.3, y: 0.7)
        model.updateGesture(token: token, displayID: 1, mode: .scroll,
                            start: point, point: point, translation: CGSize(width: 10, height: 20))
        model.endGesture(token: token)
        model.click(displayID: 1, action: "rightClick")
        model.click(displayID: 1, action: "doubleClick")
        XCTAssertTrue(model.sendText("Hello 👋🏽 世界", displayID: 1))
        let keys = ["return", "tab", "escape", "backspace", "cmd+c", "cmd+v", "cmd+a", "cmd+z"]
        for key in keys { model.sendKey(key, displayID: 1) }
        try await waitUntil { mac.controlMessages.filter { $0.action == "key" }.count == keys.count }
        XCTAssertFalse(mac.actions.contains("leftDown"), "Scrolling must not press a mouse button.")
        XCTAssertTrue(mac.actions.contains("rightClick"))
        XCTAssertTrue(mac.actions.contains("doubleClick"))
        XCTAssertEqual(mac.controlMessages.first { $0.action == "text" }?.text, "Hello 👋🏽 世界")
        XCTAssertEqual(mac.controlMessages.filter { $0.action == "key" }.compactMap(\.text), keys)
        let scroll = try XCTUnwrap(mac.controlMessages.first { $0.action == "scroll" })
        XCTAssertLessThan(try XCTUnwrap(scroll.deltaX), 0)
        XCTAssertLessThan(try XCTUnwrap(scroll.deltaY), 0)
    }

    func testInvalidInputAndConnectionAttemptsLeaveSessionUnchanged() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let count = mac.actions.count
        pinch(model, displayID: 1, at: CGPoint(x: -.infinity, y: 0.5))
        pinch(model, displayID: 1, at: CGPoint(x: 1.1, y: 0.5))
        pinch(model, displayID: 99, at: CGPoint(x: 0.5, y: 0.5))
        model.clickAtLastPointer(displayID: 99)
        for point in [CGPoint(x: .nan, y: 0.5), CGPoint(x: .infinity, y: 0.5),
                      CGPoint(x: 1.1, y: 0.5), CGPoint(x: 0.5, y: -0.01)] {
            model.tapClick(displayID: 1, at: point)
        }
        model.tapClick(displayID: 99, at: CGPoint(x: 0.5, y: 0.5))
        model.click(displayID: 1, action: "unknown")
        model.sendKey("cmd+q", displayID: 1)
        XCTAssertFalse(model.sendText("", displayID: 1))
        XCTAssertFalse(model.sendText(String(repeating: "😀", count: 1025), displayID: 1))
        model.connect(to: .hostPort(host: "127.0.0.1", port: 9), key: mac.key, name: "Duplicate")
        try await settle()
        XCTAssertEqual(mac.actions.count, count)
        XCTAssertTrue(model.isLinked)
        XCTAssertEqual(model.connectedName, "Loopback Mac")
        let inactive = DeskClientModel()
        inactive.connect(to: .hostPort(host: "127.0.0.1", port: 9), key: mac.key, name: "Inactive")
        XCTAssertFalse(inactive.isConnecting)
        XCTAssertFalse(inactive.isLinked)
    }

    // MARK: Input coalescing

    /// The whole point of holding movement back is that the release still lands where the hand
    /// actually finished. Root's drag reports every changed value and then the final one before
    /// `endGesture`, so that final coordinate is the one sitting in the pending slot.
    func testADragReleasesAtTheLastCoordinateItWasGiven() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let token = UUID(), start = CGPoint(x: 0.2, y: 0.5)
        model.updateGesture(token: token, displayID: 1, mode: .interact,
                            start: start, point: start, translation: .zero)
        try await waitUntil { mac.buttonHeld }

        // A burst well inside one coalescing window, as a real drag reports it.
        let points = (1...24).map { CGPoint(x: 0.2 + 0.025 * Double($0), y: 0.5) }
        for point in points {
            model.updateGesture(
                token: token, displayID: 1, mode: .interact, start: start, point: point,
                translation: CGSize(width: (point.x - start.x) * 1_000, height: 0)
            )
        }
        model.endGesture(token: token)
        try await waitUntil { mac.actions.last == "leftUp" }
        try await settle()

        let inputs = mac.controlMessages.filter { $0.kind == "input" }
        XCTAssertEqual(inputs.last?.action, "leftUp", "Nothing may follow the release.")
        let moves = inputs.filter { $0.action == "move" }
        let final = try XCTUnwrap(points.last)
        XCTAssertEqual(try XCTUnwrap(moves.last?.x), final.x, accuracy: 1e-9,
                       "The hand's last position has to reach the Mac before the button comes up.")
        XCTAssertLessThanOrEqual(moves.count, 6,
                                 "25 reported positions may not become 25 framed messages.")
    }

    /// Scroll is accumulated rather than replaced, so a coalesced gesture scrolls exactly as
    /// far as the same hand travel sent one delta at a time.
    func testCoalescedScrollDeltasSumToTheWholeGesture() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let token = UUID(), start = CGPoint(x: 0.5, y: 0.5)
        model.updateGesture(token: token, displayID: 1, mode: .scroll,
                            start: start, point: start, translation: .zero)
        try await waitUntil { mac.actions.contains("move") }

        let travel = 100.0, steps = 20
        for step in 1...steps {
            model.updateGesture(
                token: token, displayID: 1, mode: .scroll, start: start, point: start,
                translation: CGSize(width: 0, height: travel * Double(step) / Double(steps))
            )
        }
        model.endGesture(token: token)
        try await waitUntil { mac.controlMessages.contains { $0.action == "scroll" } }
        try await settle()

        let scrolls = mac.controlMessages.filter { $0.action == "scroll" }
        XCTAssertEqual(scrolls.compactMap(\.deltaY).reduce(0, +), -travel * 1.4, accuracy: 1e-6,
                       "Coalescing may shorten the message count, never the distance.")
        XCTAssertLessThanOrEqual(scrolls.count, 6, "20 reported deltas may not become 20 messages.")
        XCTAssertFalse(mac.actions.contains("leftDown"), "Scrolling still presses no mouse button.")
    }

    /// Stop is a revoke, not a completed gesture: whatever was held back is dropped. A position
    /// recorded before Stop arriving after it would move a pointer the user just gave up.
    func testStopDiscardsHeldMovementAndLeaksNoInputAfterwards() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let token = UUID(), start = CGPoint(x: 0.2, y: 0.5)
        model.updateGesture(token: token, displayID: 1, mode: .interact,
                            start: start, point: start, translation: .zero)
        try await waitUntil { mac.buttonHeld }
        for step in 1...24 {
            model.updateGesture(
                token: token, displayID: 1, mode: .interact, start: start,
                point: CGPoint(x: 0.2 + 0.025 * Double(step), y: 0.5),
                translation: CGSize(width: Double(step) * 25, height: 0)
            )
        }

        model.stopControl()
        try await waitUntil { mac.controlMessages.last?.kind == "stop" }
        XCTAssertEqual(mac.actions.last, "leftUp", "Stop still lifts the held button.")
        let delivered = mac.actions.count
        try await settle()

        XCTAssertEqual(mac.actions.count, delivered,
                       "A position held back before Stop must never arrive after it.")
        let kinds = mac.controlMessages.map(\.kind)
        let stop = try XCTUnwrap(kinds.lastIndex(of: "stop"))
        XCTAssertFalse(kinds[(stop + 1)...].contains("input"), "No input may follow Stop on the wire.")
        XCTAssertFalse(model.canControl)
        XCTAssertTrue(model.isLinked, "Stop revokes input and leaves viewing available.")
    }

    /// The same guarantee when the Mac takes the grant away rather than the user: the release
    /// goes out, and the movement that was waiting does not follow it.
    func testARevokedGrantDiscardsHeldMovementAndLeaksNoInputAfterwards() async throws {
        let session = try await controllableSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let token = UUID(), start = CGPoint(x: 0.3, y: 0.5)
        model.updateGesture(token: token, displayID: 1, mode: .interact,
                            start: start, point: start, translation: .zero)
        try await waitUntil { mac.buttonHeld }
        for step in 1...24 {
            model.updateGesture(
                token: token, displayID: 1, mode: .interact, start: start,
                point: CGPoint(x: 0.3 + 0.02 * Double(step), y: 0.5),
                translation: CGSize(width: Double(step) * 20, height: 0)
            )
        }

        XCTAssertTrue(mac.publishStatus("input stopped on this Mac", controlEnabled: false))
        try await waitUntil { !model.isMacControlEnabled }
        try await waitUntil { mac.actions.last == "leftUp" }
        let delivered = mac.actions.count
        try await settle()

        XCTAssertEqual(mac.actions.count, delivered,
                       "A revoked grant must not be followed by the movement it was holding.")
        XCTAssertFalse(mac.buttonHeld)
        XCTAssertFalse(model.canControl)
        XCTAssertTrue(model.isLinked, "Losing the grant ends input, not viewing.")
    }

    // MARK: Direct address and remembered Macs

    func testDirectAddressRemembersTheKeyOnlyAfterTheHandshakeSucceeds() async throws {
        let keychain = MemoryKeychain()
        let preferences = MemoryRememberedMacStore()
        let session = try await directSession(keychain: keychain, preferences: preferences)
        defer { session.close() }
        XCTAssertEqual(keychain.writeCount, 1, "The key is written exactly once, after TLS authenticated.")
        XCTAssertEqual(session.model.rememberedMac?.address, session.address)
        XCTAssertEqual(preferences.stored?.address, session.address)
        // Preferences carry the address and label only. The secret is not in them.
        let metadata = try XCTUnwrap(preferences.stored)
        let hexadecimal = session.mac.key.displayValue.replacingOccurrences(of: "-", with: "").lowercased()
        XCTAssertFalse(try XCTUnwrap(metadata.address).lowercased().contains(hexadecimal))
        XCTAssertFalse(metadata.name.lowercased().contains(hexadecimal))
        XCTAssertTrue(session.model.pairingCode.isEmpty, "The typed code is cleared once connected.")
    }

    func testARefusedDirectHandshakeRemembersNothing() async throws {
        let keychain = MemoryKeychain()
        let preferences = MemoryRememberedMacStore()
        let mac = MockMac()
        let model = DeskClientModel(keys: Self.store(keychain), preferences: preferences)
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        model.updateScene(scene, phase: .active)
        try mac.start(allowReconnect: true)
        try await waitUntil { mac.endpoint != nil }
        model.directAddress = try Self.address(for: mac)
        // A different key cannot authenticate, so nothing is ever worth storing.
        model.pairingCode = PairingKey.generate().displayValue
        model.remembersThisMac = true
        model.connectDirectly()
        try await waitUntil(timeout: 15) { model.connectionMessage != nil && !model.isConnecting }
        XCTAssertFalse(model.isLinked)
        XCTAssertEqual(keychain.writeCount, 0, "An unauthenticated Mac is never remembered.")
        XCTAssertNil(model.rememberedMac)
        XCTAssertNil(preferences.stored)
    }

    func testRememberedMacConnectsWithNoPairingCode() async throws {
        let first = try await directSession()
        let address = first.address, key = first.mac.key
        let keychain = first.keychain, preferences = first.preferences
        let port = Self.port(of: address)
        let writesBeforeReconnect = keychain.writeCount
        first.close()
        try await settle()

        // A fresh model, as if the app had been relaunched: the same keychain and
        // preferences, and no code typed anywhere.
        let mac = MockMac(key: key)
        let model = DeskClientModel(keys: Self.store(keychain), preferences: preferences)
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        XCTAssertEqual(model.rememberedMac?.address, address, "The saved Mac survives a relaunch.")
        model.updateScene(scene, phase: .active)
        try mac.start(allowReconnect: true, port: port)
        try await waitUntil { mac.endpoint != nil }
        XCTAssertTrue(model.canConnectRemembered)
        model.connectRemembered()
        try await waitUntil(timeout: 15) { model.isLinked && mac.isConnected }
        XCTAssertTrue(model.pairingCode.isEmpty, "No code was needed or used.")
        XCTAssertEqual(keychain.writeCount, writesBeforeReconnect, "A remembered connection rewrites nothing.")
    }

    func testUnexpectedDropReconnectsWhileExplicitDisconnectDoesNot() async throws {
        let session = try await directSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        XCTAssertEqual(mac.sessionCount, 1)

        mac.dropConnection()
        try await waitUntil { !model.isLinked }
        // The first backoff step is one second, so this is bounded by the schedule.
        try await waitUntil(timeout: 20) { mac.sessionCount == 2 && model.isLinked }
        XCTAssertEqual(model.reconnectAttempt, 0, "A successful reconnection resets the budget.")
        XCTAssertFalse(model.isReconnecting)

        model.disconnect()
        XCTAssertFalse(model.isLinked)
        try await settleThroughFirstRetry()
        XCTAssertEqual(mac.sessionCount, 2, "A deliberate hang-up is never undone automatically.")
        XCTAssertFalse(model.isReconnecting)
    }

    func testBackgroundReleasesTheSessionAndNeverReconnectsOnItsOwn() async throws {
        let session = try await directSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let point = CGPoint(x: 0.5, y: 0.5)
        XCTAssertTrue(mac.publish(displays: [DeskFixtures.display]))
        try await waitUntil { model.display(id: 1) != nil }
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await waitUntil { model.isMacControlEnabled }
        XCTAssertTrue(mac.sendFrame(session.frame))
        try await waitUntil { model.canControl(displayID: 1) }
        model.updateGesture(token: UUID(), displayID: 1, mode: .interact,
                            start: point, point: point, translation: .zero)
        try await waitUntil { mac.buttonHeld }

        model.updateScene(session.scene, phase: .background)
        try await waitUntil { !mac.isConnected }
        XCTAssertFalse(mac.buttonHeld, "Going to the background must not leave a button down.")
        XCTAssertGreaterThanOrEqual(mac.releaseCount, 1)
        XCTAssertFalse(model.isLinked)
        XCTAssertTrue(model.displays.isEmpty)
        try await settleThroughFirstRetry()
        XCTAssertEqual(mac.sessionCount, 1, "A backgrounded app does not reconnect behind the user.")
        XCTAssertFalse(model.isReconnecting)
    }

    func testForgetRemovesTheKeyAndTheSavedAddress() async throws {
        let session = try await directSession()
        defer { session.close() }
        let model = session.model
        XCTAssertNotNil(model.rememberedMac)

        model.forgetRememberedMac()
        XCTAssertNil(model.rememberedMac)
        XCTAssertNil(session.preferences.stored)
        XCTAssertEqual(session.preferences.clearCount, 1)
        XCTAssertTrue(session.keychain.items.isEmpty, "Forgetting removes the secret, not just the label.")
        XCTAssertFalse(model.canConnectRemembered)

        // A forgotten Mac does not come back on its own either.
        session.mac.dropConnection()
        try await waitUntil { !model.isLinked }
        try await settleThroughFirstRetry()
        XCTAssertEqual(session.mac.sessionCount, 1)
    }

    func testAFailedKeychainDeleteKeepsTheMacRememberedAndSaysWhy() async throws {
        let session = try await directSession()
        defer { session.close() }
        session.keychain.forcedStatus = errSecInteractionNotAllowed
        session.model.forgetRememberedMac()
        XCTAssertNotNil(session.model.rememberedMac, "A key still on the device is still remembered.")
        XCTAssertNotNil(session.preferences.stored)
        let message = try XCTUnwrap(session.model.connectionMessage)
        XCTAssertTrue(message.contains("\(errSecInteractionNotAllowed)"), "The message has to be actionable.")
    }

    func testUnusableDirectAddressesNeverOpenAConnection() async throws {
        let keychain = MemoryKeychain()
        let model = DeskClientModel(keys: Self.store(keychain), preferences: MemoryRememberedMacStore())
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil) }
        model.updateScene(scene, phase: .active)
        model.pairingCode = PairingKey.generate().displayValue
        for text in ["", "   ", "http://mac.local", "mac.local/desk", "user@mac.local",
                     "mac.local:0", "mac.local:65536", "fd7a::1", "0.0.0.0", "mäc.local"] {
            model.directAddress = text
            XCTAssertNil(model.directMacAddress, "\(text) must not parse.")
            XCTAssertFalse(model.canConnectDirectly)
            model.connectDirectly()
            XCTAssertFalse(model.isConnecting, "\(text) must not start a connection.")
            XCTAssertFalse(model.isLinked)
        }
        // A usable address with no code is refused just the same.
        model.directAddress = "100.64.0.42"
        model.pairingCode = ""
        XCTAssertFalse(model.canConnectDirectly)
        model.connectDirectly()
        XCTAssertFalse(model.isConnecting)
        XCTAssertEqual(keychain.writeCount, 0)
    }

    func testConnectingDirectlyWithoutAnActiveWindowDoesNothing() {
        let model = DeskClientModel(keys: Self.store(MemoryKeychain()), preferences: MemoryRememberedMacStore())
        model.directAddress = "100.64.0.42"
        model.pairingCode = PairingKey.generate().displayValue
        XCTAssertFalse(model.canConnectDirectly)
        model.connectDirectly()
        model.connectRemembered()
        XCTAssertFalse(model.isConnecting)
        XCTAssertFalse(model.isLinked)
    }

    /// A store wired to memory. No test may read or write the real keychain, so both
    /// the backing store and the service name are distinct from the app's.
    private static func store(_ keychain: MemoryKeychain) -> PairingKeyStore {
        PairingKeyStore(service: "org.visiondesk.VisionDesk.pairing.visiontests", keychain: keychain)
    }

    private static func address(for mac: MockMac) throws -> String {
        let endpoint = try XCTUnwrap(mac.endpoint)
        guard case let .hostPort(_, port) = endpoint else { throw WaitError.timeout }
        return "127.0.0.1:\(port.rawValue)"
    }

    private static func port(of address: String) -> UInt16? {
        RemoteMacAddress(string: address)?.port
    }

    /// Brings the client to a live direct-address session: an active window, a typed
    /// address and code, a real handshake, and a Mac whose listener survives the
    /// session so a reconnection has somewhere to land.
    private func directSession(keychain: MemoryKeychain = MemoryKeychain(),
                               preferences: MemoryRememberedMacStore = MemoryRememberedMacStore(),
                               remember: Bool = true) async throws -> DirectSession {
        let frame = try XCTUnwrap(DeskFixtures.jpeg(), "The platform could not encode a JPEG fixture.")
        let mac = MockMac()
        let model = DeskClientModel(keys: Self.store(keychain), preferences: preferences)
        let scene = UUID()
        model.updateScene(scene, phase: .active)
        do {
            try mac.start(allowReconnect: true)
            try await waitUntil { mac.endpoint != nil }
            let address = try Self.address(for: mac)
            model.directAddress = address
            model.pairingCode = mac.key.displayValue
            model.remembersThisMac = remember
            model.connectDirectly()
            // Nothing may be stored before the handshake completes.
            XCTAssertEqual(keychain.writeCount, 0)
            XCTAssertNil(model.rememberedMac)
            try await waitUntil(timeout: 15) { model.isLinked && mac.isConnected }
            return DirectSession(model: model, mac: mac, scene: scene, frame: frame,
                                 address: address, keychain: keychain, preferences: preferences)
        } catch {
            model.updateScene(scene, phase: nil)
            mac.stop()
            throw error
        }
    }

    /// A negative reconnection result needs more than the first backoff step to mean
    /// anything, so this covers one scheduled retry plus a handshake attempt.
    private func settleThroughFirstRetry() async throws {
        try await Task.sleep(nanoseconds: 1_800_000_000)
    }

    /// Brings the client to the state the app is in while a Mac is paired and control is
    /// granted: an active window, a completed handshake, one published display, an actual
    /// status grant and, unless `sendFrame` is false, one decoded JPEG.
    private func controllableSession(sendFrame: Bool = true) async throws -> Session {
        let frame = try XCTUnwrap(DeskFixtures.jpeg(), "The platform could not encode a JPEG fixture.")
        // In-memory stores: a Stop pressed here is recorded, and must not reach real preferences.
        let session = Session(model: DeskClientModel(keys: Self.store(MemoryKeychain()),
                                                     preferences: MemoryRememberedMacStore()),
                              mac: MockMac(), scene: UUID(), frame: frame)
        let model = session.model, mac = session.mac
        model.updateScene(session.scene, phase: .active)
        do {
            try mac.start()
            try await waitUntil { mac.endpoint != nil }
            let endpoint = try XCTUnwrap(mac.endpoint)
            model.connect(to: endpoint, key: mac.key, name: "Loopback Mac")
            try await waitUntil(timeout: 15) { model.isLinked && mac.isConnected }
            XCTAssertTrue(mac.publish(displays: [DeskFixtures.display]))
            try await waitUntil { model.display(id: 1) != nil }
            XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
            try await waitUntil { model.isMacControlEnabled }
            if sendFrame {
                XCTAssertTrue(mac.sendFrame(frame))
                try await waitUntil { model.canControl(displayID: 1) }
            }
            return session
        } catch {
            session.close()
            throw error
        }
    }

    /// A stationary Drag pinch: the press and release `DisplaySurface` drives through the gesture
    /// lifecycle. Pointer mode clicks through the native tap instead, and `tapClick` drives this
    /// same lifecycle itself rather than sending a loose press and release. An invalid coordinate
    /// or an uncontrollable display is refused inside `updateGesture`, so this is also how a
    /// rejection is exercised.
    private func pinch(_ model: DeskClientModel, displayID: UInt32,
                       at point: CGPoint, mode: ScreenInteractionMode = .interact) {
        let token = UUID()
        model.updateGesture(token: token, displayID: displayID, mode: mode,
                            start: point, point: point, translation: .zero)
        model.endGesture(token: token)
    }

    /// Polls a main-actor condition. Loopback delivery and image decoding are asynchronous,
    /// so there is no single hop to await.
    private func waitUntil(timeout: TimeInterval = 6, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1_000))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for a client or loopback event.")
                throw WaitError.timeout
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// A negative result has no event to await, so elapsed time is the only proof. This covers
    /// a heartbeat tick plus a decode hop.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    private enum WaitError: Error { case timeout }
}

@MainActor
private struct Session {
    let model: DeskClientModel
    let mac: MockMac
    let scene: UUID
    let frame: Data

    /// Removes the only scene, which is the production path that disconnects and stops
    /// discovery, then closes the mock Mac's listener.
    func close() {
        model.updateScene(scene, phase: nil)
        mac.stop()
    }
}

/// A live direct-address session, with the in-memory stores it was built on so a
/// test can assert on what was and was not persisted.
@MainActor
private struct DirectSession {
    let model: DeskClientModel
    let mac: MockMac
    let scene: UUID
    let frame: Data
    /// The address the client was given, in `RemoteMacAddress.formatted` form.
    let address: String
    let keychain: MemoryKeychain
    let preferences: MemoryRememberedMacStore

    func close() {
        model.updateScene(scene, phase: nil)
        mac.stop()
    }
}
