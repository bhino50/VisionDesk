import Combine
import DeskCore
import Foundation
import UIKit
import XCTest
@testable import VisionDesk

/// Native receiver updates can run inside UIViewRepresentable's render callback. Queue
/// cancellation must stay immediate, while the observable UI presentation waits one turn.
@MainActor
final class KeyboardPresentationTests: XCTestCase {
    func testDisablingNativeReceiverCancelsImmediatelyWithoutPublishingInsideItsUpdate() async throws {
        try await assertViewCancellationDefersOnlyPresentation(.disable)
    }

    func testDismantlingNativeReceiverCancelsImmediatelyWithoutPublishingInsideItsUpdate() async throws {
        try await assertViewCancellationDefersOnlyPresentation(.dismantle)
    }

    func testChangingNativeDestinationCancelsImmediatelyWithoutPublishingInsideItsUpdate() async throws {
        try await assertViewCancellationDefersOnlyPresentation(.destination)
    }

    func testFreshTypingCannotBeOverwrittenByDeferredCancellationPresentation() async throws {
        let session = try await preparedSession()
        let oldReceiver = makeReceiver(model: session.model, displayID: 1)
        let freshReceiver = makeReceiver(model: session.model, displayID: 2)
        defer { oldReceiver.endInputSession(); freshReceiver.endInputSession(); session.close() }
        try await holdTyping(oldReceiver, session: session)
        oldReceiver.endInputSession()
        XCTAssertEqual(session.model.keyboard.pendingCount, 0)
        // No actor hop: the new queue supersedes a deferred old cancellation before its
        // presentation task gets an opportunity to run.
        freshReceiver.insertText("fresh e\u{301}\n👩🏽‍💻")
        let freshPending = session.model.keyboard.pendingCount
        XCTAssertGreaterThan(freshPending, 1)
        XCTAssertEqual(session.model.keyboardPendingCount, freshPending)
        XCTAssertNil(session.model.keyboardNotice)
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(session.model.keyboard.pendingCount, freshPending)
        XCTAssertEqual(session.model.keyboardPendingCount, freshPending)
        XCTAssertNil(session.model.keyboardNotice, "An old deferred failure cannot replace fresh acceptance.")
    }

    func testOrdinaryModelCancellationStillPublishesSynchronously() async throws {
        let session = try await preparedSession()
        let receiver = makeReceiver(model: session.model, displayID: 1)
        defer { receiver.endInputSession(); session.close() }
        try await holdTyping(receiver, session: session)
        session.model.cancelKeyboardInput(displayID: 1)
        XCTAssertEqual(session.model.keyboard.pendingCount, 0)
        XCTAssertEqual(session.model.keyboardPendingCount, 0)
        XCTAssertNotNil(session.model.keyboardNotice)
    }

    private enum ViewCancellation { case disable, dismantle, destination }

    private func assertViewCancellationDefersOnlyPresentation(_ boundary: ViewCancellation) async throws {
        let session = try await preparedSession()
        let receiver = makeReceiver(model: session.model, displayID: 1)
        defer { receiver.endInputSession(); session.close() }
        try await holdTyping(receiver, session: session)
        let previousPresentation = session.model.keyboardPendingCount
        var insideNativeUpdate = false
        var synchronousPublications = 0
        let observation = session.model.objectWillChange.sink { _ in
            if insideNativeUpdate { synchronousPublications += 1 }
        }
        defer { observation.cancel() }
        insideNativeUpdate = true
        switch boundary {
        case .disable: configure(receiver, model: session.model, displayID: 1, enabled: false)
        case .dismantle: receiver.endInputSession()
        case .destination: configure(receiver, model: session.model, displayID: 2, enabled: true)
        }
        insideNativeUpdate = false
        XCTAssertEqual(session.model.keyboard.pendingCount, 0,
                       "Safety cannot wait for the deferred presentation flush.")
        XCTAssertEqual(synchronousPublications, 0,
                       "UIViewRepresentable updates must not synchronously publish model changes.")
        XCTAssertEqual(session.model.keyboardPendingCount, previousPresentation,
                       "Only the UI snapshot, never the actual queue, waits for the next actor turn.")
        try await Loopback.waitUntil {
            session.model.keyboardPendingCount == 0 && session.model.keyboardNotice != nil
        }
        try await Loopback.pause(0.05)
        XCTAssertEqual(session.mac.received.filter { $0.keyboardRequestID != nil }.count, 1,
                       "Deferred presentation cannot allow any cancelled queued operations to escape.")
    }

    private func preparedSession() async throws -> LoopbackSession {
        let session = try await Loopback.discoveredSession()
        do {
            let screens = (1...2).map { id in
                DisplayInfo(id: UInt32(id), name: "Synthetic portrait \(id)", width: 1080, height: 1920,
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

    private func holdTyping(_ receiver: RemoteKeyboardTextView, session: LoopbackSession) async throws {
        session.mac.keyboardAcknowledgements = false
        receiver.insertText("held first\nsecond\t尾")
        try await Loopback.waitUntil { session.mac.received.contains { $0.keyboardRequestID != nil } }
        XCTAssertGreaterThan(session.model.keyboardPendingCount, 1)
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
                           onCancel: { self.cancelFromNativeView(model, displayID: displayID) }, destinationID: displayID)
    }

    private func cancelFromNativeView(_ model: DeskClientModel, displayID: UInt32) {
        model.cancelKeyboardInputFromView(displayID: displayID)
    }
}
