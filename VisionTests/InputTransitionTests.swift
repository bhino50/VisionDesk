import CoreGraphics
import DeskCore
import Foundation
import XCTest
@testable import VisionDesk

/// One hundred rapid mode changes through the actual client and authenticated transport.
/// Four portrait streams remain fresh throughout; the peer records input and acknowledges
/// keyboard operations but never posts events to the host computer running these tests.
@MainActor
final class InputTransitionTests: XCTestCase {
    private let cycles = 25

    func testTwentyFivePortraitDragToTypingTransitionsReleaseBeforeText() async throws {
        let (session, pictures) = try await portraitSession()
        defer { pictures.cancel(); session.close() }
        let model = session.model, mac = session.mac
        for cycle in 0..<cycles {
            let display = UInt32(cycle % 4 + 1)
            try await Loopback.waitUntil { model.canControl(displayID: display) }
            let baseline = mac.received.count
            let token = UUID(), start = CGPoint(x: 0.1, y: 0.15)
            let end = CGPoint(x: 0.8 - Double(cycle % 4) * 0.05, y: 0.7 + Double(cycle % 3) * 0.04)
            model.updateGesture(token: token, displayID: display, mode: .direct,
                                start: start, point: start, translation: .zero)
            for step in 1...32 {
                let fraction = CGFloat(step) / 32
                let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                    y: start.y + (end.y - start.y) * fraction)
                model.updateGesture(token: token, displayID: display, mode: .direct,
                                    start: start, point: point,
                                    translation: CGSize(width: (point.x - start.x) * 540,
                                                        height: (point.y - start.y) * 960))
            }
            let text = "drag \(cycle) 👩🏽‍💻\n画面 \(display)"
            XCTAssertTrue(model.sendText(text, displayID: display))
            let pending = model.keyboardPendingCount
            model.finishGesture(token: token, displayID: display, mode: .direct,
                                start: start, point: end, translation: CGSize(width: 300, height: 600))
            model.updateGesture(token: token, displayID: display, mode: .direct,
                                start: start, point: start, translation: .zero)
            model.gestureStateDidReset(token: token)
            XCTAssertEqual(model.keyboardPendingCount, pending, "Retired drag, cycle \(cycle)")
            try await Loopback.waitUntil { model.keyboardPendingCount == 0 }
            let input = inputs(mac, after: baseline)
            let keyboard = input.filter { $0.keyboardRequestID != nil }
            XCTAssertEqual(Data(try typedText(keyboard).utf8), Data(text.utf8), "Cycle \(cycle)")
            let firstText = try XCTUnwrap(input.firstIndex { $0.keyboardRequestID != nil })
            let mouse = Array(input[..<firstText])
            XCTAssertEqual(mouse.filter { $0.action == "leftDown" }.count, 1)
            XCTAssertEqual(mouse.filter { $0.action == "leftUp" }.count, 1)
            XCTAssertEqual(mouse.last?.action, "leftUp", "Release precedes typing, cycle \(cycle)")
            XCTAssertEqual(mouse.last?.x ?? -1, Double(end.x), accuracy: 0.000001)
            XCTAssertEqual(mouse.last?.y ?? -1, Double(end.y), accuracy: 0.000001)
            XCTAssertTrue(input[firstText...].allSatisfy { $0.keyboardRequestID != nil })
            XCTAssertTrue(input.allSatisfy { $0.isValid && $0.displayID == display })
            XCTAssertFalse(mac.buttonHeld)
            XCTAssertNil(model.keyboardNotice)
        }
    }

    func testTwentyFivePortraitScrollToTypingTransitionsDrainWithoutScrollTail() async throws {
        let (session, pictures) = try await portraitSession()
        defer { pictures.cancel(); session.close() }
        let model = session.model, mac = session.mac
        for cycle in 0..<cycles {
            let display = UInt32(cycle % 4 + 1)
            try await Loopback.waitUntil { model.canControl(displayID: display) }
            let baseline = mac.received.count
            let token = UUID(), point = CGPoint(x: 0.5, y: 0.5)
            let x = cycle.isMultiple(of: 2) ? 80.0 : -80.0
            let y = cycle.isMultiple(of: 3) ? -100.0 : 100.0
            model.updateGesture(token: token, displayID: display, mode: .scroll,
                                start: point, point: point, translation: .zero)
            for step in 1...64 {
                model.updateGesture(token: token, displayID: display, mode: .scroll,
                                    start: point, point: point,
                                    translation: CGSize(width: x * Double(step) / 64,
                                                        height: y * Double(step) / 64))
            }
            let text = "scroll \(cycle) e\u{301}\nالعربية"
            XCTAssertTrue(model.sendText(text, displayID: display))
            let pending = model.keyboardPendingCount
            model.finishGesture(token: token, displayID: display, mode: .scroll,
                                start: point, point: point, translation: CGSize(width: x, height: y))
            model.updateGesture(token: token, displayID: display, mode: .scroll,
                                start: point, point: point, translation: CGSize(width: x * 2, height: y * 2))
            XCTAssertEqual(model.keyboardPendingCount, pending)
            try await Loopback.waitUntil { model.keyboardPendingCount == 0 }
            let input = inputs(mac, after: baseline)
            let firstText = try XCTUnwrap(input.firstIndex { $0.keyboardRequestID != nil })
            let scroll = input[..<firstText].filter { $0.action == "scroll" }
            XCTAssertEqual(scroll.compactMap(\.deltaX).reduce(0, +), -x * 1.4, accuracy: 0.000001)
            XCTAssertEqual(scroll.compactMap(\.deltaY).reduce(0, +), -y * 1.4, accuracy: 0.000001)
            XCTAssertFalse(input[firstText...].contains { $0.action == "scroll" },
                           "No old scroll may follow text, cycle \(cycle)")
            XCTAssertFalse(input.contains { $0.action == "leftDown" || $0.action == "leftUp" })
            XCTAssertEqual(Data(try typedText(input.filter { $0.keyboardRequestID != nil }).utf8), Data(text.utf8))
            XCTAssertTrue(input.allSatisfy { $0.isValid && $0.displayID == display })
            XCTAssertFalse(mac.buttonHeld)
        }
    }

    func testTwentyFiveTypingScrollTypingTransitionsCancelOnlyTheAbandonedSuffix() async throws {
        let (session, pictures) = try await portraitSession()
        defer { pictures.cancel(); session.close() }
        let model = session.model, mac = session.mac
        for cycle in 0..<cycles {
            let display = UInt32(cycle % 4 + 1)
            try await Loopback.waitUntil { model.canControl(displayID: display) }
            let baseline = mac.received.count
            mac.keyboardAcknowledgements = false
            let oldPrefix = "before \(cycle)"
            XCTAssertTrue(model.sendText(oldPrefix + "\nABANDONED", displayID: display))
            try await Loopback.waitUntil { self.inputs(mac, after: baseline).contains { $0.keyboardRequestID != nil } }
            let old = try XCTUnwrap(inputs(mac, after: baseline).first { $0.keyboardRequestID != nil })
            XCTAssertEqual(model.keyboardPendingCount, 3)

            let token = UUID(), point = CGPoint(x: 0.5, y: 0.5)
            model.updateGesture(token: token, displayID: display, mode: .scroll,
                                start: point, point: point, translation: .zero)
            XCTAssertEqual(model.keyboardPendingCount, 0, "New scroll abandons the unposted text suffix.")
            for step in 1...24 {
                model.updateGesture(token: token, displayID: display, mode: .scroll,
                                    start: point, point: point,
                                    translation: CGSize(width: 0, height: Double(step) * 4))
            }
            let newText = "after \(cycle) 🇺🇳\n新しい"
            XCTAssertTrue(model.sendText(newText, displayID: display))
            let pending = model.keyboardPendingCount
            model.finishGesture(token: token, displayID: display, mode: .scroll,
                                start: point, point: point, translation: CGSize(width: 0, height: 150))
            XCTAssertEqual(model.keyboardPendingCount, pending)
            try await Loopback.waitUntil {
                self.inputs(mac, after: baseline).filter { $0.keyboardRequestID != nil }.count == 2
            }
            let current = try XCTUnwrap(inputs(mac, after: baseline).last { $0.keyboardRequestID != nil })
            XCTAssertNotEqual(current.keyboardRequestID, old.keyboardRequestID)
            mac.keyboardAcknowledgements = true
            XCTAssertTrue(mac.send(receipt(for: old)))
            XCTAssertTrue(mac.send(receipt(for: current)))
            try await Loopback.waitUntil { model.keyboardPendingCount == 0 }
            let input = inputs(mac, after: baseline)
            let keyboard = input.filter { $0.keyboardRequestID != nil }
            XCTAssertEqual(Data(try typedText(keyboard).utf8), Data((oldPrefix + newText).utf8))
            let currentIndex = try XCTUnwrap(input.firstIndex { $0.keyboardRequestID == current.keyboardRequestID })
            XCTAssertTrue(input[..<currentIndex].contains { $0.action == "scroll" })
            XCTAssertFalse(input[currentIndex...].contains { $0.action == "scroll" })
            XCTAssertEqual(input.compactMap(\.deltaY).reduce(0, +), -24 * 4 * 1.4, accuracy: 0.000001)
            XCTAssertFalse(input.contains { $0.action == "leftDown" || $0.action == "leftUp" })
            XCTAssertNil(model.keyboardNotice)
        }
    }

    func testTwentyFiveLosingPortraitGesturesCannotRestartOverNewTyping() async throws {
        let (session, pictures) = try await portraitSession()
        defer { pictures.cancel(); session.close() }
        let model = session.model, mac = session.mac
        for cycle in 0..<cycles {
            let winnerDisplay = UInt32(cycle % 4 + 1), nextDisplay = UInt32((cycle + 1) % 4 + 1)
            try await Loopback.waitUntil {
                model.canControl(displayID: winnerDisplay) && model.canControl(displayID: nextDisplay)
            }
            let baseline = mac.received.count
            let winner = UUID(), loser = UUID(), point = CGPoint(x: 0.4, y: 0.6)
            model.updateGesture(token: winner, displayID: winnerDisplay, mode: .direct,
                                start: point, point: point, translation: .zero)
            // A second recognizer has begun while the first owns the Mac pointer. Its
            // updates were rejected, so it cannot later masquerade as a fresh gesture.
            model.updateGesture(token: loser, displayID: nextDisplay, mode: .scroll,
                                start: point, point: point, translation: .zero)
            if cycle.isMultiple(of: 2) {
                model.finishGesture(token: loser, displayID: nextDisplay, mode: .scroll,
                                    start: point, point: point, translation: .zero)
            } else {
                model.cancelGesture(token: loser)
            }
            // A mismatched callback with the winner's token must neither end it nor
            // retire it; the original display/mode still owns that active gesture.
            model.updateGesture(token: winner, displayID: nextDisplay, mode: .scroll,
                                start: point, point: point, translation: .zero)
            model.finishGesture(token: winner, displayID: nextDisplay, mode: .scroll,
                                start: point, point: point, translation: .zero)
            model.updateGesture(token: winner, displayID: 99, mode: .direct,
                                start: point, point: point, translation: .zero)
            XCTAssertEqual(model.pointer.activeDisplayID, winnerDisplay)
            let winnerFinalPoint = CGPoint(x: 0.65, y: 0.75)
            model.updateGesture(token: winner, displayID: winnerDisplay, mode: .direct,
                                start: point, point: winnerFinalPoint,
                                translation: CGSize(width: 135, height: 144))
            let text = "screen \(nextDisplay), cycle \(cycle)\n入力 👩🏽‍💻"
            XCTAssertTrue(model.sendText(text, displayID: nextDisplay))
            let pending = model.keyboardPendingCount
            model.updateGesture(token: winner, displayID: winnerDisplay, mode: .direct,
                                start: point, point: point, translation: .zero)
            model.updateGesture(token: loser, displayID: nextDisplay, mode: .scroll,
                                start: point, point: point, translation: CGSize(width: 30, height: 120))
            model.finishGesture(token: loser, displayID: nextDisplay, mode: .scroll,
                                start: point, point: point, translation: CGSize(width: 30, height: 120))
            XCTAssertEqual(model.keyboardPendingCount, pending,
                           "Losing recognizer resumed over typing, cycle \(cycle)")
            try await Loopback.waitUntil {
                model.keyboardPendingCount == 0
                    && self.inputs(mac, after: baseline).contains { $0.keyboardRequestID != nil }
            }
            let input = inputs(mac, after: baseline)
            XCTAssertEqual(Data(try typedText(input.filter { $0.keyboardRequestID != nil }).utf8), Data(text.utf8))
            let firstText = try XCTUnwrap(input.firstIndex { $0.keyboardRequestID != nil })
            XCTAssertEqual(input[..<firstText].filter { $0.action == "leftDown" }.count, 1)
            XCTAssertEqual(input[..<firstText].filter { $0.action == "leftUp" }.count, 1)
            let release = try XCTUnwrap(input[..<firstText].last { $0.action == "leftUp" })
            XCTAssertEqual(release.x ?? -1, Double(winnerFinalPoint.x), accuracy: 0.000001,
                           "Wrong-display callbacks must not retire the actual winner.")
            XCTAssertEqual(release.y ?? -1, Double(winnerFinalPoint.y), accuracy: 0.000001)
            XCTAssertFalse(input[firstText...].contains { $0.keyboardRequestID == nil },
                           "Old winning or losing recognizers cannot move after typing starts.")
            XCTAssertFalse(mac.buttonHeld)
            XCTAssertNil(model.keyboardNotice)
        }
    }

    func testCompletionOrCancellationBeforeFirstSampleCannotRestartOverTyping() async throws {
        let (session, pictures) = try await portraitSession()
        defer { pictures.cancel(); session.close() }
        let model = session.model, mac = session.mac
        let ended = UUID(), finished = UUID(), cancelled = UUID(), point = CGPoint(x: 0.4, y: 0.6)
        model.endGesture(token: ended)
        model.finishGesture(token: finished, displayID: 1, mode: .direct,
                            start: point, point: point, translation: .zero)
        model.cancelGesture(token: cancelled)
        mac.keyboardAcknowledgements = false
        let text = "new typing 👩🏽‍💻\ncontinues"
        XCTAssertTrue(model.sendText(text, displayID: 1))
        try await Loopback.waitUntil { mac.received.contains { $0.keyboardRequestID != nil } }
        let first = try XCTUnwrap(mac.received.first { $0.keyboardRequestID != nil })
        let pending = model.keyboardPendingCount
        for token in [ended, finished, cancelled] {
            model.updateGesture(token: token, displayID: 1, mode: .direct,
                                start: point, point: point, translation: .zero)
            XCTAssertEqual(model.keyboardPendingCount, pending)
            XCTAssertNil(model.pointer.activeDisplayID)
        }
        mac.keyboardAcknowledgements = true
        XCTAssertTrue(mac.send(receipt(for: first)))
        try await Loopback.waitUntil { model.keyboardPendingCount == 0 }
        XCTAssertEqual(Data(try typedText(mac.received.filter { $0.keyboardRequestID != nil }).utf8), Data(text.utf8))

        // A previously unseen token is still a legitimate new intent, not blocked by
        // the defensive handling of callbacks whose lifecycle has already ended.
        let fresh = UUID()
        model.updateGesture(token: fresh, displayID: 1, mode: .direct,
                            start: point, point: point, translation: .zero)
        try await Loopback.waitUntil { mac.buttonHeld }
        model.cancelGesture(token: fresh)
        try await Loopback.waitUntil { !mac.buttonHeld }
    }

    func testRepeatedRetirementCannotEvictOtherRecentlyFinishedTokens() async throws {
        let (session, pictures) = try await portraitSession()
        defer { pictures.cancel(); session.close() }
        let model = session.model, mac = session.mac
        let oldest = UUID(), repeated = UUID(), point = CGPoint(x: 0.4, y: 0.6)
        model.cancelGesture(token: oldest)
        for _ in 0..<62 { model.cancelGesture(token: UUID()) }
        model.cancelGesture(token: repeated)
        // There are 64 distinct retired tokens. Repeated callbacks from one of them
        // must not spend more slots and evict a different recent gesture.
        for _ in 0..<256 {
            model.cancelGesture(token: repeated)
            model.endGesture(token: repeated)
            model.finishGesture(token: repeated, displayID: 1, mode: .direct,
                                start: point, point: point, translation: .zero)
        }
        mac.keyboardAcknowledgements = false
        let text = "retirement is bounded\nwithout losing earlier tokens"
        XCTAssertTrue(model.sendText(text, displayID: 1))
        try await Loopback.waitUntil { mac.received.contains { $0.keyboardRequestID != nil } }
        let first = try XCTUnwrap(mac.received.first { $0.keyboardRequestID != nil })
        let pending = model.keyboardPendingCount
        model.updateGesture(token: oldest, displayID: 1, mode: .direct,
                            start: point, point: point, translation: .zero)
        XCTAssertEqual(model.keyboardPendingCount, pending)
        XCTAssertNil(model.pointer.activeDisplayID)
        mac.keyboardAcknowledgements = true
        XCTAssertTrue(mac.send(receipt(for: first)))
        try await Loopback.waitUntil { model.keyboardPendingCount == 0 }
        XCTAssertEqual(try typedText(mac.received.filter { $0.keyboardRequestID != nil }), text)
    }

    private func portraitSession() async throws -> (LoopbackSession, Task<Void, Never>) {
        let session = try await Loopback.discoveredSession()
        let displays = (1...4).map { index in
            DisplayInfo(id: UInt32(index), name: "Portrait \(index)", width: 1080, height: 1920,
                        originX: Double(index - 2) * 540, originY: 0, pointWidth: 540, pointHeight: 960)
        }
        let frame = try XCTUnwrap(DeskFixtures.jpeg(width: 54, height: 96))
        XCTAssertTrue(session.mac.publish(displays: displays))
        XCTAssertTrue(session.mac.publishStatus("Synthetic control enabled", controlEnabled: true))
        let pictures = Task { @MainActor in
            while !Task.isCancelled {
                for display in displays { _ = session.mac.sendFrame(frame, displayID: display.id) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        do {
            try await Loopback.waitUntil {
                session.model.keyboard.isSupported && displays.allSatisfy { session.model.canControl(displayID: $0.id) }
            }
            return (session, pictures)
        } catch {
            pictures.cancel()
            session.close()
            throw error
        }
    }

    private func inputs(_ mac: MockMac, after index: Int) -> [DeskMessage] {
        Array(mac.received.dropFirst(index)).filter { $0.kind == "input" }
    }

    private func receipt(for message: DeskMessage) -> DeskMessage {
        DeskMessage(kind: "keyboardResult", keyboardRequestID: message.keyboardRequestID, keyboardResult: "posted")
    }

    private func typedText(_ messages: [DeskMessage]) throws -> String {
        try messages.map { message in
            switch (message.action, message.text) {
            case ("text", let text?): return text
            case ("key", "return"): return "\n"
            case ("key", "tab"): return "\t"
            default:
                XCTFail("Unexpected keyboard operation in a mode-transition transcript.")
                throw TransitionError.unexpectedKeyboardOperation
            }
        }.joined()
    }

    private enum TransitionError: Error { case unexpectedKeyboardOperation }
}
