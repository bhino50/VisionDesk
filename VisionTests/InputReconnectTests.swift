import CoreGraphics
import DeskCore
import Foundation
import XCTest
@testable import VisionDesk

/// These use twelve real TLS reconnects. Old recognizer callbacks and acknowledgements
/// are deliberately delivered after the new session is ready, while new typing is pending.
/// The mock posts no operating-system input; only its authenticated wire transcript is read.
@MainActor
final class InputReconnectTests: XCTestCase {
    func testFourDroppedPortraitDragsCannotResumeOverNewSessionTyping() async throws {
        let rig = try await ReconnectRig.make()
        defer { rig.close() }
        let model = rig.session.model, mac = rig.session.mac
        for cycle in 0..<4 {
            let oldDisplay = UInt32(cycle + 1), newDisplay = UInt32((cycle + 1) % 4 + 1)
            let mode: ScreenInteractionMode = cycle.isMultiple(of: 2) ? .direct : .interact
            let token = UUID(), start = CGPoint(x: 0.2, y: 0.3)
            model.updateGesture(token: token, displayID: oldDisplay, mode: mode,
                                start: start, point: start, translation: .zero)
            try await Loopback.waitUntil { mac.buttonHeld }
            // No actor suspension while these samples fill the coalescer. The last
            // movement belongs to the dying connection, never its replacement.
            for step in 1...48 {
                model.updateGesture(token: token, displayID: oldDisplay, mode: mode,
                                    start: start, point: CGPoint(x: 0.2 + Double(step) / 64, y: 0.8),
                                    translation: CGSize(width: step * 8, height: step * 10))
            }
            let oldStream = try XCTUnwrap(model.display(id: oldDisplay))
            let newSession = try await rig.dropAndReconnect()
            XCTAssertNil(oldStream.image)
            XCTAssertFalse(mac.buttonHeld)
            XCTAssertNil(model.pointer.activeDisplayID)
            XCTAssertTrue(model.pointedDisplayIDs.isEmpty)
            XCTAssertFalse(model.canControl)
            try await rig.grantPortraitControl()

            let text = "recovered \(cycle) 👩🏽‍💻\n画面 \(newDisplay)"
            let current = try await rig.holdTyping(text, displayID: newDisplay, in: newSession)
            let pending = model.keyboardPendingCount
            model.updateGesture(token: token, displayID: oldDisplay, mode: mode,
                                start: start, point: CGPoint(x: 0.95, y: 0.95),
                                translation: CGSize(width: 500, height: 800))
            model.finishGesture(token: token, displayID: oldDisplay, mode: mode,
                                start: start, point: CGPoint(x: 0.95, y: 0.95), translation: .zero)
            model.gestureStateDidReset(token: token)
            model.cancelGesture(token: token)
            XCTAssertEqual(model.keyboardPendingCount, pending)
            try await rig.finishTyping(current)
            let recovered = inputs(mac, in: newSession)
            XCTAssertTrue(recovered.allSatisfy { $0.keyboardRequestID != nil },
                          "No queued movement or release from the previous session may arrive.")
            XCTAssertEqual(Data(try typedText(recovered).utf8), Data(text.utf8))
            try await assertFreshInputWorks(rig, displayID: newDisplay, sessionNumber: newSession)
        }
    }

    func testFourReconnectsDiscardOldKeyboardReceiptsAndPendingScroll() async throws {
        let rig = try await ReconnectRig.make()
        defer { rig.close() }
        let model = rig.session.model, mac = rig.session.mac
        for cycle in 0..<4 {
            let display = UInt32(cycle + 1)
            let oldSession = mac.sessionCount
            let old = try await rig.holdTyping("old \(cycle)\nUNPOSTED SUFFIX", displayID: display, in: oldSession)
            let token = UUID(), point = CGPoint(x: 0.5, y: 0.5)
            model.updateGesture(token: token, displayID: display, mode: .scroll,
                                start: point, point: point, translation: .zero)
            XCTAssertEqual(model.keyboardPendingCount, 0, "The new scroll intentionally abandons the old suffix.")
            for step in 1...64 {
                model.updateGesture(token: token, displayID: display, mode: .scroll,
                                    start: point, point: point,
                                    translation: CGSize(width: step * 2, height: step * 3))
            }
            let newSession = try await rig.dropAndReconnect()
            XCTAssertEqual(model.keyboardPendingCount, 0)
            try await rig.grantPortraitControl()
            let text = "current \(cycle) e\u{301}\n新しい session"
            let current = try await rig.holdTyping(text, displayID: display, in: newSession)
            let pending = model.keyboardPendingCount
            XCTAssertNotEqual(current.keyboardRequestID, old.keyboardRequestID)
            // The old request ID arrives over the new authenticated channel, where it
            // must still be unable to acknowledge or retry a different operation.
            XCTAssertTrue(mac.send(receipt(for: old, result: "posted")))
            XCTAssertTrue(mac.send(receipt(for: old, result: "busy")))
            model.updateGesture(token: token, displayID: display, mode: .scroll,
                                start: point, point: point, translation: CGSize(width: 600, height: 900))
            model.finishGesture(token: token, displayID: display, mode: .scroll,
                                start: point, point: point, translation: CGSize(width: 600, height: 900))
            let barrier = "Old receipt checked in session \(newSession)"
            XCTAssertTrue(mac.publishStatus(barrier, controlEnabled: true))
            try await Loopback.waitUntil { model.statusText == barrier }
            XCTAssertEqual(model.keyboardPendingCount, pending)
            XCTAssertNil(model.keyboardNotice)
            try await rig.finishTyping(current)
            let recovered = inputs(mac, in: newSession)
            XCTAssertEqual(Data(try typedText(recovered).utf8), Data(text.utf8))
            XCTAssertFalse(recovered.contains { $0.action == "scroll" })
            XCTAssertFalse(recovered.contains { $0.text?.contains("UNPOSTED") == true })
            XCTAssertFalse(mac.buttonHeld)
            try await assertFreshInputWorks(rig, displayID: display, sessionNumber: newSession)
        }
    }

    func testFourModeSwitchBurstsLeaveNoOldRecognizerLiveAfterReconnect() async throws {
        let rig = try await ReconnectRig.make()
        defer { rig.close() }
        let model = rig.session.model, mac = rig.session.mac
        let modes: [ScreenInteractionMode] = [.direct, .pointer, .scroll, .interact]
        for cycle in 0..<4 {
            var oldGestures: [(UUID, UInt32, ScreenInteractionMode)] = []
            let point = CGPoint(x: 0.4, y: 0.6)
            for index in 0..<20 {
                let token = UUID(), display = UInt32((cycle + index) % 4 + 1), mode = modes[index % modes.count]
                oldGestures.append((token, display, mode))
                model.updateGesture(token: token, displayID: display, mode: mode,
                                    start: point, point: point, translation: .zero)
                model.updateGesture(token: token, displayID: display, mode: mode,
                                    start: point, point: CGPoint(x: 0.6, y: 0.7),
                                    translation: CGSize(width: 40, height: 60))
                if index < 19 { model.cancelGesture(token: token) }
            }
            let newSession = try await rig.dropAndReconnect()
            try await rig.grantPortraitControl()
            let display = UInt32(cycle + 1), text = "mode burst \(cycle) 🇺🇳\n続ける"
            let current = try await rig.holdTyping(text, displayID: display, in: newSession)
            let pending = model.keyboardPendingCount
            for (token, oldDisplay, mode) in oldGestures {
                model.updateGesture(token: token, displayID: oldDisplay, mode: mode,
                                    start: point, point: CGPoint(x: 0.9, y: 0.9),
                                    translation: CGSize(width: 500, height: 700))
                model.finishGesture(token: token, displayID: oldDisplay, mode: mode,
                                    start: point, point: point, translation: .zero)
                model.gestureStateDidReset(token: token)
            }
            XCTAssertEqual(model.keyboardPendingCount, pending)
            XCTAssertNil(model.pointer.activeDisplayID)
            try await rig.finishTyping(current)
            let recovered = inputs(mac, in: newSession)
            XCTAssertTrue(recovered.allSatisfy { $0.keyboardRequestID != nil })
            XCTAssertEqual(Data(try typedText(recovered).utf8), Data(text.utf8))
            XCTAssertFalse(mac.buttonHeld)
            try await assertFreshInputWorks(rig, displayID: display, sessionNumber: newSession)
        }
    }

    private func assertFreshInputWorks(_ rig: ReconnectRig, displayID: UInt32,
                                       sessionNumber: Int) async throws {
        let model = rig.session.model, mac = rig.session.mac
        let baseline = inputs(mac, in: sessionNumber).count
        let start = CGPoint(x: 0.25, y: 0.35), end = CGPoint(x: 0.7, y: 0.8), token = UUID()
        model.updateGesture(token: token, displayID: displayID, mode: .direct,
                            start: start, point: start, translation: .zero)
        model.finishGesture(token: token, displayID: displayID, mode: .direct,
                            start: start, point: end, translation: CGSize(width: 240, height: 432))
        let scroll = UUID()
        model.updateGesture(token: scroll, displayID: displayID, mode: .scroll,
                            start: end, point: end, translation: .zero)
        model.updateGesture(token: scroll, displayID: displayID, mode: .scroll,
                            start: end, point: end, translation: CGSize(width: 15, height: 30))
        XCTAssertTrue(model.sendText("fresh ✓", displayID: displayID))
        try await Loopback.waitUntil { model.keyboardPendingCount == 0 }
        let fresh = Array(inputs(mac, in: sessionNumber).dropFirst(baseline))
        XCTAssertEqual(fresh.filter { $0.action == "leftDown" }.count, 1)
        XCTAssertEqual(fresh.filter { $0.action == "leftUp" }.count, 1)
        let release = try XCTUnwrap(fresh.first { $0.action == "leftUp" })
        XCTAssertEqual(release.x ?? -1, Double(end.x), accuracy: 0.000001)
        XCTAssertEqual(release.y ?? -1, Double(end.y), accuracy: 0.000001)
        XCTAssertEqual(fresh.compactMap(\.deltaX).reduce(0, +), -21, accuracy: 0.000001)
        XCTAssertEqual(fresh.compactMap(\.deltaY).reduce(0, +), -42, accuracy: 0.000001)
        let keyboardIndex = try XCTUnwrap(fresh.firstIndex { $0.keyboardRequestID != nil })
        XCTAssertFalse(fresh[keyboardIndex...].contains { $0.keyboardRequestID == nil })
        XCTAssertEqual(try typedText(fresh.filter { $0.keyboardRequestID != nil }), "fresh ✓")
        XCTAssertTrue(fresh.allSatisfy { $0.isValid && $0.displayID == displayID })
        XCTAssertFalse(mac.buttonHeld)
        XCTAssertNil(model.keyboardNotice)
    }

    private func inputs(_ mac: MockMac, in session: Int) -> [DeskMessage] {
        mac.received(inSession: session).filter { $0.kind == "input" }
    }

    private func receipt(for message: DeskMessage, result: String) -> DeskMessage {
        DeskMessage(kind: "keyboardResult", keyboardRequestID: message.keyboardRequestID, keyboardResult: result)
    }

    private func typedText(_ messages: [DeskMessage]) throws -> String {
        try messages.map { message in
            switch (message.action, message.text) {
            case ("text", let text?): return text
            case ("key", "return"): return "\n"
            case ("key", "tab"): return "\t"
            default:
                XCTFail("Non-keyboard input crossed into the recovered typing transcript.")
                throw InputReconnectError.unexpectedInput
            }
        }.joined()
    }

    private enum InputReconnectError: Error { case unexpectedInput }

    @MainActor
    private final class ReconnectRig {
        let session: LoopbackSession
        private let displays: [DisplayInfo]
        private var pictures: Task<Void, Never>?

        private init(session: LoopbackSession, displays: [DisplayInfo], frame: Data) {
            self.session = session
            self.displays = displays
            pictures = Task { @MainActor in
                while !Task.isCancelled {
                    if session.mac.isConnected {
                        for display in displays { _ = session.mac.sendFrame(frame, displayID: display.id) }
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }

        static func make() async throws -> ReconnectRig {
            let session = try await Loopback.directSession(linkPolicy: Loopback.reportOnlyPolicy)
            let displays = (1...4).map { index in
                DisplayInfo(id: UInt32(index), name: "Reconnect portrait \(index)", width: 1080, height: 1920,
                            originX: Double(index - 2) * 540, originY: 0, pointWidth: 540, pointHeight: 960)
            }
            let frame = try XCTUnwrap(DeskFixtures.jpeg(width: 54, height: 96))
            let rig = ReconnectRig(session: session, displays: displays, frame: frame)
            do { try await rig.grantPortraitControl(); return rig }
            catch { rig.close(); throw error }
        }

        func grantPortraitControl() async throws {
            XCTAssertTrue(session.mac.publish(displays: displays))
            XCTAssertTrue(session.mac.publishStatus("Synthetic control enabled", controlEnabled: true))
            try await Loopback.waitUntil {
                self.session.model.keyboard.isSupported
                    && self.displays.allSatisfy { self.session.model.canControl(displayID: $0.id) }
            }
        }

        func dropAndReconnect() async throws -> Int {
            let next = session.mac.sessionCount + 1
            session.mac.keyboardAcknowledgements = true
            session.mac.dropConnection()
            try await Loopback.waitUntil(timeout: 15) {
                self.session.mac.sessionCount == next && self.session.model.isLinked && self.session.mac.isConnected
            }
            XCTAssertFalse(session.model.isMacControlEnabled)
            XCTAssertTrue(session.model.pointedDisplayIDs.isEmpty)
            XCTAssertEqual(session.model.keyboardPendingCount, 0)
            return next
        }

        func holdTyping(_ text: String, displayID: UInt32, in number: Int) async throws -> DeskMessage {
            session.mac.keyboardAcknowledgements = false
            let before = session.mac.received(inSession: number).filter { $0.keyboardRequestID != nil }.count
            XCTAssertTrue(session.model.sendText(text, displayID: displayID))
            try await Loopback.waitUntil {
                self.session.mac.received(inSession: number).filter { $0.keyboardRequestID != nil }.count > before
            }
            return try XCTUnwrap(session.mac.received(inSession: number)
                .filter { $0.keyboardRequestID != nil }.dropFirst(before).first)
        }

        func finishTyping(_ message: DeskMessage) async throws {
            session.mac.keyboardAcknowledgements = true
            XCTAssertTrue(session.mac.send(DeskMessage(kind: "keyboardResult",
                                                       keyboardRequestID: message.keyboardRequestID,
                                                       keyboardResult: "posted")))
            try await Loopback.waitUntil { self.session.model.keyboardPendingCount == 0 }
        }

        func close() { pictures?.cancel(); pictures = nil; session.close() }
    }
}
