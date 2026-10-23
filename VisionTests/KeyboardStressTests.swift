import DeskCore
import Foundation
import UIKit
import XCTest
@testable import VisionDesk

/// The real UIKit text receiver feeds the real acknowledged delivery queue. The small
/// peer below only records wire messages and supplies explicit acknowledgements, so queue
/// pressure and ordering remain deterministic without touching a person's Mac or keyboard.
@MainActor
final class KeyboardStressTests: XCTestCase {
    private static let corpusSeed: UInt64 = 0x5649_5349_4F4E_4453

    func testTwelveSeededUnicodeMultilineEditsPreserveBytesAndKeyOrder() throws {
        var random = CorpusRandom(seed: Self.corpusSeed)
        for index in 0..<12 {
            let rig = KeyboardRig()
            defer { rig.finish() }
            let edit = Self.corpus(random: &random, index: index)
            XCTAssertLessThan(edit.utf8.count, KeyboardDelivery.maximumBytes)
            rig.receiver.insertText(edit)
            rig.receiver.textViewDidChange(rig.receiver)
            XCTAssertEqual(rig.receiver.text, "", "Seeded edit \(index) must be admitted completely.")
            rig.commands.send("cmd+z")

            let delivered = try rig.drain()
            XCTAssertGreaterThan(delivered.count, 10, "Exercise multiple packets, not a short input.")
            XCTAssertTrue(delivered.allSatisfy { $0.isValid && ($0.text?.utf8.count ?? 0) <= 512 })
            XCTAssertEqual(Set(delivered.compactMap(\.keyboardRequestID)).count, delivered.count)
            XCTAssertEqual(delivered.last?.action, "key")
            XCTAssertEqual(delivered.last?.text, "cmd+z")
            let typed = try Self.typedText(Array(delivered.dropLast()))
            XCTAssertEqual(Data(typed.utf8), Data(Self.normalizedNewlines(edit).utf8),
                           "UTF-8 preservation and newline order, corpus \(index).")
            XCTAssertEqual(rig.delivery.pendingCount, 0)
            XCTAssertEqual(rig.transmissions.count, delivered.count,
                           "A delegate notification cannot duplicate an admitted edit.")
        }
    }

    func testMaximumByteEditsAreAdmittedButOneMoreByteStaysLocalUntilEdited() throws {
        let emoji = "👩🏽‍💻"
        let multibyte = String(repeating: emoji, count: KeyboardDelivery.maximumBytes / emoji.utf8.count)
        let exact = multibyte + String(repeating: "x", count: KeyboardDelivery.maximumBytes - multibyte.utf8.count)
        for edit in [String(repeating: "x", count: KeyboardDelivery.maximumBytes), exact] {
            let rig = KeyboardRig()
            defer { rig.finish() }
            XCTAssertEqual(edit.utf8.count, KeyboardDelivery.maximumBytes)
            rig.receiver.insertText(edit + "x")
            XCTAssertEqual(rig.receiver.text, edit + "x")
            XCTAssertTrue(rig.transmissions.isEmpty, "Oversize edits are rejected atomically.")
            XCTAssertEqual(rig.delivery.pendingCount, 0)
            rig.commands.send("backspace")
            XCTAssertEqual(rig.receiver.text, "", "Deleting the excess byte makes the retained edit sendable.")
            let delivered = try rig.drain()
            XCTAssertEqual(Data(try Self.typedText(delivered).utf8), Data(edit.utf8))
            XCTAssertFalse(delivered.contains { $0.action == "key" && $0.text == "backspace" },
                           "The corrective Delete belongs to the retained local edit.")
        }
    }

    func testFourUnicodeEditsCrossAuthenticatedLoopbackForPortraitDisplay() async throws {
        let session = try await Loopback.discoveredSession()
        let receiver = RemoteKeyboardTextView(), commands = RemoteKeyboardCommands()
        defer {
            commands.detach(receiver)
            receiver.endInputSession()
            session.close()
        }
        let portrait = DisplayInfo(id: 1, name: "Portrait test", width: 1080, height: 1920,
                                   originX: 0, originY: 0, pointWidth: 1080, pointHeight: 1920)
        try await session.grantControl(displays: [portrait])
        let pictures = Task { @MainActor in
            while !Task.isCancelled {
                _ = session.mac.sendFrame(session.frame)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { pictures.cancel() }
        try await Loopback.waitUntil { session.model.keyboard.isSupported }
        receiver.configure(isEnabled: true, focusRequest: UUID(),
                           onText: { session.model.sendText($0, displayID: 1) },
                           onKey: { session.model.sendKey($0, displayID: 1) },
                           onCancel: { session.model.cancelKeyboardInput() }, destinationID: 1)
        commands.attach(receiver)
        var random = CorpusRandom(seed: Self.corpusSeed)
        for index in 0..<4 {
            XCTAssertTrue(session.mac.sendFrame(session.frame))
            try await Loopback.waitUntil { session.model.canControl(displayID: 1) }
            let before = session.mac.received.filter { $0.keyboardRequestID != nil }.count
            let edit = Self.corpus(random: &random, index: index)
            receiver.insertText(edit)
            commands.send("tab")
            XCTAssertEqual(receiver.text, "")
            try await Loopback.waitUntil { session.model.keyboardPendingCount == 0 }
            let delivered = Array(session.mac.received.filter { $0.keyboardRequestID != nil }.dropFirst(before))
            XCTAssertTrue(delivered.allSatisfy { $0.isValid && $0.displayID == portrait.id })
            XCTAssertEqual(Data(try Self.typedText(delivered).utf8),
                           Data((Self.normalizedNewlines(edit) + "\t").utf8))
            XCTAssertNil(session.model.keyboardNotice)
        }
    }

    func testSaturatedQueueRetainsUnicodeEditAndRetrySendsItOnceBeforeShortcut() throws {
        let rig = KeyboardRig()
        defer { rig.finish() }
        rig.receiver.insertText(String(repeating: "\n", count: KeyboardDelivery.maximumOperations))
        XCTAssertEqual(rig.delivery.pendingCount, KeyboardDelivery.maximumOperations)
        XCTAssertEqual(rig.transmissions.count, 1, "Only one operation may await acknowledgement.")

        var random = CorpusRandom(seed: Self.corpusSeed)
        let held = Self.corpus(random: &random, index: 3)
        rig.receiver.insertText(held)
        rig.commands.send("tab")
        XCTAssertEqual(rig.receiver.text, held)
        XCTAssertEqual(rig.delivery.pendingCount, KeyboardDelivery.maximumOperations)
        XCTAssertEqual(rig.transmissions.count, 1, "Neither rejected text nor its following key may overtake.")
        let prefix = try rig.drain()
        XCTAssertEqual(prefix.count, KeyboardDelivery.maximumOperations)
        XCTAssertEqual(try Self.typedText(prefix), String(repeating: "\n", count: KeyboardDelivery.maximumOperations))

        rig.commands.retryRemainingText()
        rig.commands.retryRemainingText()
        rig.commands.send("cmd+shift+z")
        XCTAssertEqual(rig.receiver.text, "")
        let suffix = try rig.drain()
        XCTAssertEqual(suffix.last?.text, "cmd+shift+z")
        XCTAssertEqual(Data(try Self.typedText(Array(suffix.dropLast())).utf8),
                       Data(Self.normalizedNewlines(held).utf8))
        XCTAssertEqual(Set((prefix + suffix).compactMap(\.keyboardRequestID)).count,
                       prefix.count + suffix.count, "Retrying retained text cannot replay accepted operations.")
    }

    func testTwoHundredFiftySevenNewlinesAreRejectedWithoutPartialTyping() throws {
        let rig = KeyboardRig()
        defer { rig.finish() }
        let overLimit = String(repeating: "\n", count: KeyboardDelivery.maximumOperations + 1)
        rig.receiver.insertText(overLimit)
        XCTAssertEqual(rig.receiver.text, overLimit)
        XCTAssertTrue(rig.transmissions.isEmpty)
        XCTAssertEqual(rig.delivery.pendingCount, 0)
        rig.receiver.deleteBackward()
        XCTAssertEqual(rig.receiver.text, "")
        XCTAssertEqual(try rig.drain().count, KeyboardDelivery.maximumOperations)
    }

    func testControlLossDestinationChangeAndDismantleRejectLateAcknowledgements() throws {
        enum Boundary: CaseIterable { case controlLoss, destinationChange, dismantle }
        for boundary in Boundary.allCases {
            let rig = KeyboardRig()
            defer { rig.finish() }
            rig.receiver.insertText("old 👩🏽‍💻\nsecond line\t尾")
            let old = try XCTUnwrap(rig.transmissions.last)
            XCTAssertGreaterThan(rig.delivery.pendingCount, 1)
            switch boundary {
            case .controlLoss: rig.configure(enabled: false)
            case .destinationChange: rig.configure(destination: 2)
            case .dismantle: rig.finish()
            }
            XCTAssertEqual(rig.delivery.pendingCount, 0)
            rig.acknowledge(old, result: "posted")
            rig.acknowledge(old, result: "busy")
            XCTAssertEqual(rig.transmissions.count, 1, "A late receipt cannot restart cancelled work.")

            rig.configure(enabled: true, destination: boundary == .destinationChange ? 2 : 1)
            rig.receiver.insertText("new e\u{301} 🇺🇳")
            if boundary == .dismantle {
                XCTAssertEqual(rig.transmissions.count, 1, "A dismantled native receiver cannot return.")
                continue
            }
            let current = try XCTUnwrap(rig.transmissions.last)
            XCTAssertNotEqual(current.keyboardRequestID, old.keyboardRequestID)
            XCTAssertEqual(current.displayID, boundary == .destinationChange ? 2 : 1)
            let before = rig.delivery.pendingCount
            rig.acknowledge(old, result: "posted")
            XCTAssertEqual(rig.delivery.pendingCount, before)
            XCTAssertEqual(try Self.typedText(rig.drain()), "new e\u{301} 🇺🇳")
        }
    }

    func testBusyUnknownAndDuplicateReceiptsCannotReorderUnicodeInput() async throws {
        let rig = KeyboardRig()
        defer { rig.finish() }
        let edit = "前" + String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 40) + "\r\nبعد\t끝"
        rig.receiver.insertText(edit)
        rig.commands.send("cmd+a")
        let first = try XCTUnwrap(rig.transmissions.last)
        let pending = rig.delivery.pendingCount
        rig.delivery.receive(DeskMessage(kind: "keyboardResult", keyboardRequestID: UUID().uuidString,
                                         keyboardResult: "posted"))
        XCTAssertEqual(rig.delivery.pendingCount, pending)
        rig.acknowledge(first, result: "busy")
        XCTAssertEqual(rig.delivery.pendingCount, pending)
        try await Loopback.waitUntil(timeout: 1) { rig.transmissions.count == 2 }
        XCTAssertEqual(rig.transmissions[0], rig.transmissions[1],
                       "Busy promises zero work, so only the same operation may be retried.")
        rig.acknowledge(first, result: "posted")
        let afterFirst = rig.delivery.pendingCount
        let transmissions = rig.transmissions.count
        rig.acknowledge(first, result: "posted")
        XCTAssertEqual(rig.delivery.pendingCount, afterFirst)
        XCTAssertEqual(rig.transmissions.count, transmissions)
        let delivered = [first] + (try rig.drain())
        XCTAssertEqual(delivered.last?.text, "cmd+a")
        XCTAssertEqual(Data(try Self.typedText(Array(delivered.dropLast())).utf8),
                       Data(Self.normalizedNewlines(edit).utf8))
    }

    func testRetiredMouseCallbacksCannotDiscardInFlightMultilineTyping() async throws {
        for retirement in ["completion", "cancellation"] {
            for callback in ["update", "completion"] {
                let session = try await Loopback.discoveredSession()
                defer { session.close() }
                try await session.grantControl()
                try await Loopback.waitUntil { session.model.keyboard.isSupported }
                let model = session.model, mac = session.mac
                let token = UUID(), start = CGPoint(x: 0.3, y: 0.4)
                model.updateGesture(token: token, displayID: 1, mode: .interact,
                                    start: start, point: start, translation: .zero)
                try await Loopback.waitUntil { mac.buttonHeld }
                if retirement == "completion" {
                    model.finishGesture(token: token, displayID: 1, mode: .interact,
                                        start: start, point: start, translation: .zero)
                } else {
                    model.cancelGesture(token: token)
                }
                try await Loopback.waitUntil { !mac.buttonHeld }

                mac.keyboardAcknowledgements = false
                let edit = "first 👩🏽‍💻\nsecond e\u{301}\t第三"
                XCTAssertTrue(model.sendText(edit, displayID: 1))
                try await Loopback.waitUntil { mac.received.contains { $0.keyboardRequestID != nil } }
                let first = try XCTUnwrap(mac.received.first { $0.keyboardRequestID != nil })
                let pending = model.keyboardPendingCount
                XCTAssertEqual(pending, 5)
                let pointerCount = mac.received.filter { $0.kind == "input" && $0.keyboardRequestID == nil }.count

                // UIKit can deliver an old recognizer's final callback after keyboard input
                // begins. PointerInput already retires this token, so it must be a no-op
                // for the keyboard queue as well as for the pointer.
                if callback == "update" {
                    model.updateGesture(token: token, displayID: 1, mode: .interact,
                                        start: start, point: CGPoint(x: 0.6, y: 0.7),
                                        translation: CGSize(width: 20, height: 20))
                } else {
                    model.finishGesture(token: token, displayID: 1, mode: .interact,
                                        start: start, point: CGPoint(x: 0.6, y: 0.7),
                                        translation: CGSize(width: 20, height: 20))
                }
                let variant = "\(retirement), late \(callback)"
                XCTAssertEqual(model.keyboardPendingCount, pending,
                               "A retired mouse callback must not discard admitted text: \(variant)")
                XCTAssertNil(model.keyboardNotice, variant)

                mac.keyboardAcknowledgements = true
                XCTAssertTrue(mac.send(DeskMessage(kind: "keyboardResult",
                                                   keyboardRequestID: first.keyboardRequestID,
                                                   keyboardResult: "posted")))
                try await Loopback.waitUntil { model.keyboardPendingCount == 0 }
                let delivered = mac.received.filter { $0.keyboardRequestID != nil }
                XCTAssertEqual(Data(try Self.typedText(delivered).utf8), Data(edit.utf8), variant)
                XCTAssertEqual(mac.received.filter { $0.kind == "input" && $0.keyboardRequestID == nil }.count,
                               pointerCount, "Retired pointer work stays retired: \(variant)")
            }
        }
    }

    func testInvalidAndUnknownMouseCallbacksCannotDiscardInFlightTyping() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        try await session.grantControl()
        try await Loopback.waitUntil { session.model.keyboard.isSupported }
        let model = session.model, mac = session.mac
        mac.keyboardAcknowledgements = false
        let edit = "first 👩🏽‍💻\nsecond e\u{301}\t第三"
        XCTAssertTrue(model.sendText(edit, displayID: 1))
        try await Loopback.waitUntil { mac.received.contains { $0.keyboardRequestID != nil } }
        let first = try XCTUnwrap(mac.received.first { $0.keyboardRequestID != nil })
        let pending = model.keyboardPendingCount
        let point = CGPoint(x: 0.4, y: 0.5)
        let rejected: [(String, () -> Void)] = [
            ("unplaced display click", { model.clickAtLastPointer(displayID: 99) }),
            ("non-finite direct tap", { model.directTapClick(displayID: 1, at: CGPoint(x: .nan, y: 0.5)) }),
            ("out-of-bounds pointer tap", { model.tapClick(displayID: 1, at: CGPoint(x: -1, y: 0.5)) }),
            ("unknown button action", { model.click(displayID: 1, action: "unknown") }),
            ("invalid placement", { model.placePointer(displayID: 1, at: CGPoint(x: 2, y: 0.5)) }),
            ("unknown completion", {
                model.finishGesture(token: UUID(), displayID: 1, mode: .interact,
                                    start: point, point: point, translation: .zero)
            }),
            ("non-finite gesture", {
                model.updateGesture(token: UUID(), displayID: 1, mode: .interact,
                                    start: point, point: CGPoint(x: .nan, y: 0.5), translation: .zero)
            }),
            ("missing display gesture", {
                model.updateGesture(token: UUID(), displayID: 99, mode: .interact,
                                    start: point, point: point, translation: .zero)
            })
        ]
        for (name, action) in rejected {
            action()
            XCTAssertEqual(model.keyboardPendingCount, pending, name)
            XCTAssertNil(model.keyboardNotice, name)
        }
        mac.keyboardAcknowledgements = true
        XCTAssertTrue(mac.send(DeskMessage(kind: "keyboardResult", keyboardRequestID: first.keyboardRequestID,
                                           keyboardResult: "posted")))
        try await Loopback.waitUntil { model.keyboardPendingCount == 0 }
        XCTAssertEqual(Data(try Self.typedText(mac.received.filter { $0.keyboardRequestID != nil }).utf8),
                       Data(edit.utf8))
        XCTAssertFalse(mac.received.contains { $0.kind == "input" && $0.keyboardRequestID == nil })
    }

    func testAcceptedMouseIntentsStillCancelRemainingTypingBeforeInput() async throws {
        enum Intent: String, CaseIterable {
            case directTap, pointerTap, rightClick, doubleClick, placement, drag, scroll, trackpad
        }
        for intent in Intent.allCases {
            let session = try await Loopback.discoveredSession()
            defer { session.close() }
            try await session.grantControl()
            try await Loopback.waitUntil { session.model.keyboard.isSupported }
            let model = session.model, mac = session.mac
            let point = CGPoint(x: 0.4, y: 0.5)
            model.placePointer(displayID: 1, at: point)
            try await Loopback.waitUntil { mac.actions.contains("move") }
            mac.keyboardAcknowledgements = false
            XCTAssertTrue(model.sendText("first\nsecond\tthird", displayID: 1))
            try await Loopback.waitUntil { mac.received.contains { $0.keyboardRequestID != nil } }
            let first = try XCTUnwrap(mac.received.first { $0.keyboardRequestID != nil })
            XCTAssertEqual(model.keyboardPendingCount, 5)
            let before = mac.received.filter { $0.kind == "input" && $0.keyboardRequestID == nil }.count
            let token = UUID()
            switch intent {
            case .directTap: model.directTapClick(displayID: 1, at: point)
            case .pointerTap: model.tapClick(displayID: 1, at: point)
            case .rightClick: model.click(displayID: 1, action: "rightClick")
            case .doubleClick: model.click(displayID: 1, action: "doubleClick")
            case .placement: model.placePointer(displayID: 1, at: CGPoint(x: 0.6, y: 0.7))
            case .drag, .scroll, .trackpad:
                let mode: ScreenInteractionMode = intent == .drag ? .interact : intent == .scroll ? .scroll : .pointer
                model.updateGesture(token: token, displayID: 1, mode: mode,
                                    start: point, point: point, translation: .zero)
                model.finishGesture(token: token, displayID: 1, mode: mode,
                                    start: point, point: CGPoint(x: 0.6, y: 0.7),
                                    translation: CGSize(width: 20, height: 20))
            }
            XCTAssertEqual(model.keyboardPendingCount, 0, intent.rawValue)
            XCTAssertTrue(model.keyboardNotice?.contains("stopped") == true, intent.rawValue)
            try await Loopback.waitUntil {
                mac.received.filter { $0.kind == "input" && $0.keyboardRequestID == nil }.count > before
            }
            XCTAssertTrue(mac.send(DeskMessage(kind: "keyboardResult", keyboardRequestID: first.keyboardRequestID,
                                               keyboardResult: "posted")))
            try await Loopback.pause(0.05)
            XCTAssertEqual(mac.received.filter { $0.keyboardRequestID != nil }.count, 1,
                           "The accepted mouse intent cancels the unposted suffix: \(intent.rawValue)")
            XCTAssertEqual(model.keyboardPendingCount, 0)
        }
    }

    func testRivalGestureCannotClaimTheKeyboardInterruptionHook() {
        let pointer = PointerInput()
        pointer.canControl = { _ in true }
        pointer.isLinked = { true }
        pointer.send = { _ in true }
        let winner = UUID(), rival = UUID(), point = CGPoint(x: 0.4, y: 0.5)
        var interruptions = 0
        pointer.updateGesture(token: winner, displayID: 1, mode: .interact,
                              start: point, point: point, translation: .zero,
                              beforeInput: { interruptions += 1 })
        XCTAssertEqual(interruptions, 1)
        pointer.updateGesture(token: rival, displayID: 2, mode: .scroll,
                              start: point, point: point, translation: .zero,
                              beforeInput: { interruptions += 1 })
        pointer.finishGesture(token: winner, displayID: 2, mode: .interact,
                              start: point, point: point, translation: .zero,
                              beforeInput: { interruptions += 1 })
        pointer.finishGesture(token: winner, displayID: 1, mode: .scroll,
                              start: point, point: point, translation: .zero,
                              beforeInput: { interruptions += 1 })
        XCTAssertEqual(interruptions, 1, "Rejected rival or mismatched metadata cannot interrupt typing.")
        XCTAssertEqual(pointer.activeDisplayID, 1)
        pointer.cancelGesture(token: winner)
    }

    func testMarkedUnicodeCandidatesNeverEscapeBeforeCommitOrAcrossDestinationChange() throws {
        let rig = KeyboardRig()
        defer { rig.finish() }
        for candidate in ["にほん", "日本語", "العَرَبِيَّة", "हिन्दी", "👩🏽‍💻e\u{301}"] {
            rig.receiver.setMarkedText(candidate, selectedRange: NSRange(location: candidate.utf16.count, length: 0))
            rig.receiver.textViewDidChange(rig.receiver)
            rig.commands.retryRemainingText()
            rig.commands.send("tab")
            XCTAssertTrue(rig.transmissions.isEmpty)
            XCTAssertNotNil(rig.receiver.markedTextRange)
        }
        rig.configure(destination: 2)
        rig.receiver.unmarkText()
        XCTAssertTrue(rig.transmissions.isEmpty, "Moving to another Mac screen cannot commit the old candidate.")
        let committed = "नमस्ते e\u{301} 👩🏽‍💻"
        rig.receiver.setMarkedText(committed, selectedRange: NSRange(location: committed.utf16.count, length: 0))
        rig.receiver.unmarkText()
        rig.receiver.unmarkText()
        rig.receiver.textViewDidChange(rig.receiver)
        let delivered = try rig.drain()
        XCTAssertTrue(delivered.allSatisfy { $0.displayID == 2 })
        XCTAssertEqual(Data(try Self.typedText(delivered).utf8), Data(committed.utf8))
    }

    private static func corpus(random: inout CorpusRandom, index: Int) -> String {
        let pieces = ["plain text ", "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇺🇳", "e\u{301}", "中文日本語", "العَرَبِيَّة",
                      "हिन्दी", "한글", "\r\n", "\n", "\r", "\t", " "]
        // A grapheme larger than one packet exercises the scalar fallback, alongside normal
        // emoji clusters and combining sequences that should stay together when they fit.
        var result = "case\(index):" + String(repeating: "x", count: 513)
        result += "a" + String(repeating: "\u{301}", count: 300) + "\n"
        for _ in 0..<180 { result += pieces[random.nextIndex(pieces.count)] }
        return result + "\nend\t✓"
    }

    private static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func typedText(_ messages: [DeskMessage]) throws -> String {
        try messages.map { message in
            switch (message.action, message.text) {
            case ("text", let text?): return text
            case ("key", "return"): return "\n"
            case ("key", "tab"): return "\t"
            default:
                XCTFail("Unexpected operation in typed-text transcript.")
                throw TranscriptError.unexpectedOperation
            }
        }.joined()
    }

    private enum TranscriptError: Error { case unexpectedOperation, didNotDrain }

    private struct CorpusRandom {
        var seed: UInt64
        mutating func nextIndex(_ count: Int) -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(count))
        }
    }

    @MainActor
    private final class KeyboardRig {
        let receiver = RemoteKeyboardTextView()
        let commands = RemoteKeyboardCommands()
        let delivery = KeyboardDelivery()
        private(set) var transmissions: [DeskMessage] = []
        private var allowed = true
        private var destination: UInt32 = 1
        private var focusRequest = UUID()

        init() {
            delivery.enable()
            delivery.canControl = { [weak self] id in self?.allowed == true && self?.destination == id }
            delivery.send = { [weak self] message in self?.transmissions.append(message); return true }
            commands.attach(receiver)
            configure()
        }

        func configure(enabled: Bool = true, destination: UInt32? = nil) {
            allowed = enabled
            if let destination, self.destination != destination {
                self.destination = destination
                focusRequest = UUID()
            }
            let target = self.destination
            receiver.configure(isEnabled: enabled, focusRequest: focusRequest,
                               onText: { [weak self] in self?.delivery.enqueueText($0, displayID: target) ?? false },
                               onKey: { [weak self] in _ = self?.delivery.enqueueKey($0, displayID: target) },
                               onCancel: { [weak self] in self?.delivery.cancel() }, destinationID: target)
        }

        func acknowledge(_ message: DeskMessage, result: String) {
            delivery.receive(DeskMessage(kind: "keyboardResult", keyboardRequestID: message.keyboardRequestID,
                                         keyboardResult: result))
        }

        func drain() throws -> [DeskMessage] {
            var delivered: [DeskMessage] = []
            for _ in 0..<KeyboardDelivery.maximumOperations + 1 {
                guard delivery.pendingCount > 0 else { return delivered }
                let current = try XCTUnwrap(transmissions.last)
                let before = delivery.pendingCount
                delivered.append(current)
                acknowledge(current, result: "posted")
                XCTAssertEqual(delivery.pendingCount, before - 1, "One receipt retires exactly one operation.")
            }
            XCTFail("Bounded keyboard queue did not drain.")
            throw TranscriptError.didNotDrain
        }

        func finish() {
            commands.detach(receiver)
            receiver.endInputSession()
            delivery.cancel(endSession: true)
        }
    }
}
