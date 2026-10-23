import DeskCore
import Foundation
import UIKit
import XCTest
@testable import DeskTransport
@testable import VisionDesk

/// Keyboard recovery across genuine TLS connections. An uncertain old operation is never
/// replayed, and old transport callbacks cannot acknowledge a new session's current request.
@MainActor
final class KeyboardReconnectTests: XCTestCase {
    func testManualReconnectRejectsOldChannelCallbacksAndNeverReplaysPendingTyping() async throws {
        try await checkReconnect(automatic: false)
    }

    func testAutomaticReconnectRejectsOldReceiptsAndRestoresBothPortraitKeyboards() async throws {
        try await checkReconnect(automatic: true)
    }

    func testFourSuccessiveReconnectsKeepRequestsDistinctAndOldTextOutOfEveryNewSession() async throws {
        let log = ChannelLog()
        let session = try await Loopback.directSession(makeConnection: Loopback.recordingFactory(log))
        defer { session.close() }
        var requestIDs = Set<String>()
        for cycle in 0..<4 {
            try await grantPortraits(session)
            let receiver = makeReceiver(model: session.model, displayID: UInt32(cycle % 2 + 1))
            defer { receiver.endInputSession() }
            let old = try await hold("uncertain \(cycle)\nnever replay\t尾", receiver: receiver, session: session)
            XCTAssertTrue(requestIDs.insert(try XCTUnwrap(old.keyboardRequestID)).inserted)
            let before = session.mac.sessionCount
            session.model.disconnect()
            receiver.endInputSession()
            XCTAssertEqual(session.model.keyboardPendingCount, 0)
            XCTAssertFalse(session.model.keyboard.isSupported)
            try await Loopback.waitUntil { !session.mac.isConnected }
            session.mac.keyboardAcknowledgements = true
            session.model.pairingCode = session.mac.key.displayValue
            session.model.connectDirectly()
            try await Loopback.waitUntil(timeout: 15) {
                session.model.isLinked && session.mac.sessionCount == before + 1
            }
            try await grantPortraits(session)
            XCTAssertTrue(session.mac.received(inSession: before + 1).filter { $0.keyboardRequestID != nil }.isEmpty)
            let fresh = makeReceiver(model: session.model, displayID: UInt32((cycle + 1) % 2 + 1))
            defer { fresh.endInputSession() }
            let text = "fresh \(cycle) e\u{301}\n👩🏽‍💻\tمرحبا"
            fresh.insertText(text)
            try await Loopback.waitUntil { session.model.keyboardPendingCount == 0 }
            let delivered = session.mac.received(inSession: before + 1).filter { $0.keyboardRequestID != nil }
            XCTAssertEqual(Data(try reconstructedText(delivered).utf8), Data(text.utf8))
            for message in delivered {
                XCTAssertTrue(requestIDs.insert(try XCTUnwrap(message.keyboardRequestID)).inserted,
                              "Reconnection must not reuse any prior keyboard request identifier.")
            }
        }
        XCTAssertEqual(session.mac.sessionCount, 5)
        XCTAssertEqual(log.channels.count, 5)
    }

    private func checkReconnect(automatic: Bool) async throws {
        let log = ChannelLog()
        let session = try await Loopback.directSession(makeConnection: Loopback.recordingFactory(log))
        let model = session.model, mac = session.mac
        defer { session.close() }
        try await grantPortraits(session)
        let receiver = makeReceiver(model: model, displayID: 1)
        defer { receiver.endInputSession() }
        let oldMessage = try await hold("uncertain old line\nnever replay\t終", receiver: receiver, session: session)
        let oldCallback = try XCTUnwrap(log.channels.first?.onMessage)
        let oldState = try XCTUnwrap(log.channels.first?.onState)
        if automatic {
            mac.dropConnection()
            try await Loopback.waitUntil { !model.isLinked && model.isReconnecting }
        } else {
            // Schedule the production busy retry, then disconnect in this same actor turn.
            // Its delayed task must never transmit into either the old or new session.
            oldCallback(DeskMessage(kind: "keyboardResult", keyboardRequestID: oldMessage.keyboardRequestID,
                                    keyboardResult: "busy"))
            model.disconnect()
            try await Loopback.waitUntil { !mac.isConnected }
        }
        receiver.endInputSession()
        XCTAssertEqual(model.keyboardPendingCount, 0)
        XCTAssertFalse(model.keyboard.isSupported)
        oldCallback(DeskMessage(kind: "capabilities", keyboardAcknowledgements: true))
        XCTAssertFalse(model.keyboard.isSupported, "A callback from the closed channel cannot renegotiate input.")
        mac.keyboardAcknowledgements = true
        if !automatic {
            model.pairingCode = mac.key.displayValue
            model.connectDirectly()
        }
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && mac.sessionCount == 2 }
        try await grantPortraits(session)
        XCTAssertEqual(log.channels.count, 2)
        XCTAssertTrue(mac.received(inSession: 2).filter { $0.keyboardRequestID != nil }.isEmpty,
                      "An uncertain operation and its remaining text must not cross a reconnection.")

        let freshReceiver = makeReceiver(model: model, displayID: 2)
        defer { freshReceiver.endInputSession() }
        let freshText = "new e\u{301}\n第二 👩🏽‍💻\tمرحبا"
        let current = try await hold(freshText, receiver: freshReceiver, session: session)
        let pending = model.keyboardPendingCount
        XCTAssertNotEqual(current.keyboardRequestID, oldMessage.keyboardRequestID)
        // This uses the *current* identifier. The connection-generation gate, not just
        // KeyboardDelivery's request matching, must reject an old channel's callback.
        oldCallback(DeskMessage(kind: "keyboardResult", keyboardRequestID: current.keyboardRequestID,
                                keyboardResult: "posted"))
        oldCallback(DeskMessage(kind: "status", status: "obsolete revocation", controlEnabled: false))
        oldState(.disconnected("obsolete channel closed"))
        XCTAssertEqual(model.keyboardPendingCount, pending)
        XCTAssertTrue(model.isLinked, "A retired channel's close event cannot tear down the replacement session.")
        XCTAssertTrue(model.isMacControlEnabled)
        XCTAssertEqual(mac.received(inSession: 2).filter { $0.keyboardRequestID != nil }.count, 1)

        // A real late old receipt on the replacement channel is authenticated but still
        // belongs to the old request. A following status is an ordered receive barrier.
        XCTAssertTrue(mac.send(DeskMessage(kind: "keyboardResult", keyboardRequestID: oldMessage.keyboardRequestID,
                                           keyboardResult: "posted")))
        XCTAssertTrue(mac.publishStatus("late receipt barrier", controlEnabled: true))
        try await Loopback.waitUntil { model.statusText == "late receipt barrier" }
        XCTAssertEqual(model.keyboardPendingCount, pending)
        mac.keyboardAcknowledgements = true
        XCTAssertTrue(mac.send(DeskMessage(kind: "keyboardResult", keyboardRequestID: current.keyboardRequestID,
                                           keyboardResult: "posted")))
        try await Loopback.waitUntil { model.keyboardPendingCount == 0 }
        var delivered = mac.received(inSession: 2).filter { $0.keyboardRequestID != nil }
        XCTAssertEqual(Data(try reconstructedText(delivered).utf8), Data(freshText.utf8))
        XCTAssertTrue(delivered.allSatisfy { $0.displayID == 2 })

        // Switch back to the other portrait after recovery; the new destination must get
        // only its new text, including composed Unicode and ordered line/tab operations.
        let otherReceiver = makeReceiver(model: model, displayID: 1)
        defer { otherReceiver.endInputSession() }
        let before = delivered.count
        let otherText = "other portrait 🇺🇳\nà bientôt\t終"
        otherReceiver.insertText(otherText)
        try await Loopback.waitUntil { model.keyboardPendingCount == 0 }
        delivered = Array(mac.received(inSession: 2).filter { $0.keyboardRequestID != nil }.dropFirst(before))
        XCTAssertEqual(Data(try reconstructedText(delivered).utf8), Data(otherText.utf8))
        XCTAssertTrue(delivered.allSatisfy { $0.displayID == 1 })
        XCTAssertEqual(mac.received(inSession: 1).filter { $0.keyboardRequestID != nil }.count, 1)
    }

    private func grantPortraits(_ session: LoopbackSession) async throws {
        let screens = (1...2).map { id in
            DisplayInfo(id: UInt32(id), name: "Portrait \(id)", width: 1080, height: 1920,
                        originX: Double(id - 1) * 1080, originY: 0, pointWidth: 1080, pointHeight: 1920)
        }
        try await session.grantControl(displays: screens)
        try await Loopback.waitUntil { session.model.keyboard.isSupported }
        let portrait = try XCTUnwrap(DeskFixtures.jpeg(width: 27, height: 48))
        for screen in screens { XCTAssertTrue(session.mac.sendFrame(portrait, displayID: screen.id)) }
        try await Loopback.waitUntil {
            screens.allSatisfy { session.model.display(id: $0.id)?.imageSize == CGSize(width: 27, height: 48) }
        }
    }

    private func makeReceiver(model: DeskClientModel, displayID: UInt32) -> RemoteKeyboardTextView {
        let receiver = RemoteKeyboardTextView()
        receiver.configure(isEnabled: true, focusRequest: UUID(),
                           onText: { model.sendText($0, displayID: displayID) },
                           onKey: { model.sendKey($0, displayID: displayID) },
                           onCancel: { model.cancelKeyboardInput(displayID: displayID) }, destinationID: displayID)
        return receiver
    }

    private func hold(_ text: String, receiver: RemoteKeyboardTextView,
                      session: LoopbackSession) async throws -> DeskMessage {
        let number = session.mac.sessionCount
        let before = session.mac.received(inSession: number).filter { $0.keyboardRequestID != nil }.count
        session.mac.keyboardAcknowledgements = false
        receiver.insertText(text)
        try await Loopback.waitUntil {
            session.mac.received(inSession: number).filter { $0.keyboardRequestID != nil }.count == before + 1
        }
        XCTAssertGreaterThan(session.model.keyboardPendingCount, 1)
        XCTAssertEqual(receiver.text, "")
        return try XCTUnwrap(session.mac.received(inSession: number).last { $0.keyboardRequestID != nil })
    }

    private func reconstructedText(_ messages: [DeskMessage]) throws -> String {
        try messages.map { message in
            if message.action == "text" { return try XCTUnwrap(message.text) }
            switch message.text {
            case "return": return "\n"
            case "tab": return "\t"
            default: XCTFail("Unexpected keyboard action in recovered text"); return ""
            }
        }.joined()
    }
}
