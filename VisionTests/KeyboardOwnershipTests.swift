import DeskCore
import Foundation
import UIKit
import XCTest
@testable import VisionDesk

/// Real native receivers route through the production model and authenticated loopback.
/// No receiver is attached to a window, so these lifecycle tests never raise a keyboard.
@MainActor
final class KeyboardOwnershipTests: XCTestCase {
    func testDismissingUnrelatedPortraitKeyboardPreservesOtherScreensTyping() async throws {
        try await assertUnrelatedCancellationIsHarmless(.dismiss)
    }

    func testPausingUnrelatedPortraitKeyboardPreservesOtherScreensTyping() async throws {
        try await assertUnrelatedCancellationIsHarmless(.disable)
    }

    func testDetachingUnrelatedPortraitKeyboardPreservesOtherScreensTyping() async throws {
        try await assertUnrelatedCancellationIsHarmless(.detach)
    }

    func testRotatingUnrelatedPortraitPreservesOtherScreensTyping() async throws {
        try await assertDisplayChange(.rotate, displayID: 1, preservesTyping: true)
    }

    func testRemovingUnrelatedPortraitPreservesOtherScreensTyping() async throws {
        try await assertDisplayChange(.remove, displayID: 1, preservesTyping: true)
    }

    func testRotatingOwningPortraitCancelsItsPendingTyping() async throws {
        try await assertDisplayChange(.rotate, displayID: 2, preservesTyping: false)
    }

    func testRemovingOwningPortraitCancelsItsPendingTyping() async throws {
        try await assertDisplayChange(.remove, displayID: 2, preservesTyping: false)
    }

    func testDismissingOwningPortraitKeyboardStillCancelsItsPendingTyping() async throws {
        let session = try await preparedSession()
        let receiver = makeReceiver(model: session.model, displayID: 2)
        defer { receiver.endInputSession(); session.close() }
        let first = try await holdTyping(receiver, session: session)
        receiver.endInputSession()
        XCTAssertEqual(session.model.keyboardPendingCount, 0)
        XCTAssertNotNil(session.model.keyboardNotice)
        XCTAssertTrue(session.mac.send(DeskMessage(kind: "keyboardResult", keyboardRequestID: first.keyboardRequestID,
                                                   keyboardResult: "posted")))
        try await Loopback.pause(0.08)
        XCTAssertEqual(session.mac.received.filter { $0.keyboardRequestID != nil }.count, 1,
                       "Ending the actual destination must not send its remaining queued operations.")
    }

    private enum Cancellation { case dismiss, disable, detach }
    private enum DisplayChange { case rotate, remove }
    private static let edit = "first 👩🏽‍💻\nsecond e\u{301}\t第三"

    private func assertUnrelatedCancellationIsHarmless(_ cancellation: Cancellation) async throws {
        let session = try await preparedSession()
        let unrelated = makeReceiver(model: session.model, displayID: 1)
        let owner = makeReceiver(model: session.model, displayID: 2)
        defer { unrelated.endInputSession(); owner.endInputSession(); session.close() }
        let first = try await holdTyping(owner, session: session)
        let pending = session.model.keyboardPendingCount
        switch cancellation {
        case .dismiss:
            unrelated.endInputSession()
        case .disable:
            configure(unrelated, model: session.model, displayID: 1, enabled: false)
        case .detach:
            // The native lifecycle hook sees no window, as it does after UIKit detaches it.
            unrelated.didMoveToWindow()
        }
        XCTAssertEqual(session.model.keyboardPendingCount, pending,
                       "Only the destination that owns the admitted queue may cancel it.")
        XCTAssertNil(session.model.keyboardNotice)
        session.mac.keyboardAcknowledgements = true
        XCTAssertTrue(session.mac.send(DeskMessage(kind: "keyboardResult", keyboardRequestID: first.keyboardRequestID,
                                                   keyboardResult: "posted")))
        try await Loopback.waitUntil { session.model.keyboardPendingCount == 0 }
        let delivered = session.mac.received.filter { $0.keyboardRequestID != nil }
        XCTAssertEqual(Data(try reconstructedText(delivered).utf8), Data(Self.edit.utf8),
                       "Background receiver lifecycle events cannot discard another screen's bytes.")
        XCTAssertTrue(delivered.allSatisfy { $0.displayID == 2 })
    }

    private func assertDisplayChange(_ change: DisplayChange, displayID: UInt32,
                                     preservesTyping: Bool) async throws {
        let session = try await preparedSession()
        let owner = makeReceiver(model: session.model, displayID: 2)
        defer { owner.endInputSession(); session.close() }
        let first = try await holdTyping(owner, session: session)
        let pending = session.model.keyboardPendingCount
        var displays = session.model.displays.map(\.info)
        switch change {
        case .rotate:
            let index = try XCTUnwrap(displays.firstIndex { $0.id == displayID })
            let old = displays[index]
            displays[index] = DisplayInfo(id: old.id, name: old.name, width: old.height, height: old.width,
                                          originX: old.originX, originY: old.originY,
                                          pointWidth: old.pointHeight, pointHeight: old.pointWidth)
        case .remove:
            displays.removeAll { $0.id == displayID }
        }
        // Deliver a decoded authenticated message at the production inbound boundary.
        session.model.receive(DeskMessage(kind: "displays", displays: displays))
        if preservesTyping {
            XCTAssertEqual(session.model.keyboardPendingCount, pending,
                           "Only a change to the typing destination may cancel its admitted queue.")
            XCTAssertNil(session.model.keyboardNotice)
            XCTAssertTrue(session.model.canControl(displayID: 2))
        } else {
            XCTAssertEqual(session.model.keyboardPendingCount, 0)
            XCTAssertNotNil(session.model.keyboardNotice)
        }
        session.mac.keyboardAcknowledgements = true
        XCTAssertTrue(session.mac.send(DeskMessage(kind: "keyboardResult", keyboardRequestID: first.keyboardRequestID,
                                                   keyboardResult: "posted")))
        try await Loopback.waitUntil { session.model.keyboardPendingCount == 0 }
        if preservesTyping {
            let delivered = session.mac.received.filter { $0.keyboardRequestID != nil }
            XCTAssertEqual(Data(try reconstructedText(delivered).utf8), Data(Self.edit.utf8))
            XCTAssertTrue(delivered.allSatisfy { $0.displayID == 2 })
        } else {
            try await Loopback.pause(0.08)
            XCTAssertEqual(session.mac.received.filter { $0.keyboardRequestID != nil }.count, 1,
                           "Changing or removing the destination must not resume its cancelled queue.")
        }
    }

    private func preparedSession() async throws -> LoopbackSession {
        let session = try await Loopback.discoveredSession()
        do {
            let screens = (1...2).map { id in
                DisplayInfo(id: UInt32(id), name: "Portrait \(id)", width: 1080, height: 1920,
                            originX: Double(id - 1) * 1080, originY: 0, pointWidth: 1080, pointHeight: 1920)
            }
            try await session.grantControl(displays: screens)
            try await Loopback.waitUntil { session.model.keyboard.isSupported }
            return session
        } catch {
            session.close()
            throw error
        }
    }

    private func holdTyping(_ receiver: RemoteKeyboardTextView, session: LoopbackSession) async throws -> DeskMessage {
        session.mac.keyboardAcknowledgements = false
        receiver.insertText(Self.edit)
        try await Loopback.waitUntil { session.mac.received.contains { $0.keyboardRequestID != nil } }
        XCTAssertGreaterThan(session.model.keyboardPendingCount, 1)
        XCTAssertEqual(receiver.text, "", "The complete edit was admitted before cancellation.")
        return try XCTUnwrap(session.mac.received.first { $0.keyboardRequestID != nil })
    }

    private func makeReceiver(model: DeskClientModel, displayID: UInt32) -> RemoteKeyboardTextView {
        let receiver = RemoteKeyboardTextView()
        configure(receiver, model: model, displayID: displayID, enabled: true)
        return receiver
    }

    private func configure(_ receiver: RemoteKeyboardTextView, model: DeskClientModel,
                           displayID: UInt32, enabled: Bool) {
        receiver.configure(isEnabled: enabled, focusRequest: UUID(),
                           onText: { model.sendText($0, displayID: displayID) },
                           onKey: { model.sendKey($0, displayID: displayID) },
                           onCancel: { model.cancelKeyboardInput(displayID: displayID) }, destinationID: displayID)
    }

    private func reconstructedText(_ messages: [DeskMessage]) throws -> String {
        try messages.map { message in
            if message.action == "text" { return try XCTUnwrap(message.text) }
            switch message.text {
            case "return": return "\n"
            case "tab": return "\t"
            default: XCTFail("Unexpected keyboard action while reconstructing the edit"); return ""
            }
        }.joined()
    }
}
