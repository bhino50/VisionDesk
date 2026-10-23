import DeskCore
import UIKit
import XCTest
@testable import VisionDesk

/// Calls the production UITextView/UIKeyInput methods rather than simulating a second text
/// routing implementation. Focus probes replace only UIKit's window/responder boundary so
/// these lifecycle checks cannot raise a keyboard or steal focus from the app under test.
@MainActor
final class RemoteKeyboardInputTests: XCTestCase {
    func testExplicitRetrySendsRetainedTextOnceWithoutAddingAKey() {
        let recorder = Recorder()
        recorder.acceptsText = false
        let view = makeView(recorder)
        let commands = RemoteKeyboardCommands()
        commands.attach(view)
        view.insertText("held")
        recorder.events.removeAll()
        recorder.acceptsText = true
        commands.retryRemainingText()
        commands.retryRemainingText()
        XCTAssertEqual(recorder.events, [.text("held")])
        XCTAssertEqual(view.text, "")
        view.endInputSession()
    }

    func testSameDestinationRefocusPreservesRejectedTextWithoutAutomaticallySending() {
        let recorder = Recorder()
        recorder.acceptsText = false
        let view = RemoteKeyboardTextView()
        configure(view, recorder: recorder, destinationID: 1)
        view.insertText("held")
        recorder.events.removeAll()
        recorder.acceptsText = true
        configure(view, recorder: recorder, focusRequest: UUID(), destinationID: 1)
        XCTAssertEqual(view.text, "held", "Show keyboard only renews focus on the same screen")
        XCTAssertTrue(recorder.events.isEmpty, "SwiftUI configuration must not mutate delivery state")
        view.retryRemainingText()
        XCTAssertEqual(recorder.events, [.text("held")])
        view.endInputSession()
    }

    func testRefocusStillDiscardsCompositionAndChangedDestinationDiscardsRetainedText() {
        let recorder = Recorder()
        recorder.acceptsText = false
        let view = RemoteKeyboardTextView()
        configure(view, recorder: recorder, destinationID: 1)
        view.setMarkedText("candidate", selectedRange: NSRange(location: 9, length: 0))
        configure(view, recorder: recorder, focusRequest: UUID(), destinationID: 1)
        XCTAssertEqual(view.text, "")
        view.insertText("old screen")
        recorder.events.removeAll()
        configure(view, recorder: recorder, focusRequest: UUID(), destinationID: 2)
        recorder.acceptsText = true
        view.retryRemainingText()
        XCTAssertEqual(view.text, "")
        XCTAssertTrue(recorder.events.isEmpty)
        view.endInputSession()
    }

    func testRetryCannotCommitMarkedTextOrSendAfterDisableDetachOrDismantle() {
        let recorder = Recorder()
        let view = makeView(recorder)
        let commands = RemoteKeyboardCommands()
        commands.attach(view)
        view.setMarkedText("candidate", selectedRange: NSRange(location: 9, length: 0))
        commands.retryRemainingText()
        XCTAssertTrue(recorder.events.isEmpty)
        configure(view, recorder: recorder, isEnabled: false)
        commands.retryRemainingText()
        XCTAssertTrue(recorder.events.isEmpty)
        configure(view, recorder: recorder)
        recorder.acceptsText = false
        view.insertText("held")
        recorder.events.removeAll()
        recorder.acceptsText = true
        commands.detach(view)
        commands.retryRemainingText()
        XCTAssertEqual(view.text, "held")
        XCTAssertTrue(recorder.events.isEmpty)
        commands.attach(view)
        view.endInputSession()
        commands.retryRemainingText()
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testOnlyTheKeyboardWindowsFocusLossCancelsPendingDeliveryAndComposition() {
        let view = FocusProbe()
        var cancellations = 0
        var sent: [String] = []
        view.configure(isEnabled: true, focusRequest: UUID(), onText: { sent.append($0); return true },
                       onKey: { _ in }, onCancel: { cancellations += 1 })
        view.setMarkedText("pending", selectedRange: NSRange(location: 7, length: 0))
        NotificationCenter.default.post(name: UIWindow.didResignKeyNotification, object: UIWindow())
        XCTAssertEqual(cancellations, 0)
        NotificationCenter.default.post(name: UIWindow.didResignKeyNotification, object: view.probeWindow)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(view.text, "")
        XCTAssertTrue(sent.isEmpty, "Losing the keyboard window cannot commit a candidate to the Mac.")
        view.endInputSession()
    }

    func testNativeTypingSendsUnicodeImmediatelyAndDoesNotReplayDelegateNotifications() {
        let recorder = Recorder()
        let view = makeView(recorder)
        view.insertText("hello")
        view.insertText(" 👩🏽‍💻 e\u{301} 中文")
        XCTAssertEqual(recorder.events, [.text("hello"), .text(" 👩🏽‍💻 e\u{301} 中文")])
        XCTAssertEqual(view.text, "", "The field is an input sink, not an unsynchronized local document.")
        view.textViewDidChange(view)
        XCTAssertEqual(recorder.events.count, 2, "A native delegate callback cannot duplicate the input.")
    }

    func testNewlinesAndTabsKeepTheirOrderBetweenTextPackets() {
        let recorder = Recorder()
        let view = makeView(recorder)
        view.insertText("one\r\ntwo\t三\n")
        XCTAssertEqual(recorder.events, [.text("one\r\ntwo\t三\n")],
                       "The whole edit is admitted atomically; the delivery queue preserves key ordering.")
        view.deleteBackward()
        view.deleteBackward()
        XCTAssertEqual(Array(recorder.events.suffix(2)), [.key("backspace"), .key("backspace")],
                       "Delete must still act on the Mac when the native sink is empty.")
    }

    func testRealMarkedTextIsHeldUntilNativeCommitAndSentOnce() {
        let recorder = Recorder()
        let view = makeView(recorder)
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(view.markedTextRange, "Exercise UIKit's actual composition state.")
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        view.textViewDidChange(view)
        XCTAssertTrue(recorder.events.isEmpty, "Provisional candidates must not reach the Mac.")
        view.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
        view.unmarkText()
        XCTAssertEqual(recorder.events, [.text("你")])
        view.unmarkText()
        view.textViewDidChange(view)
        XCTAssertEqual(recorder.events, [.text("你")], "Commit and change callbacks must not double-send.")
    }

    func testNativeInsertReplacesMarkedCandidateInsteadOfSendingBothCandidates() {
        let recorder = Recorder()
        let view = makeView(recorder)
        view.setMarkedText("ka", selectedRange: NSRange(location: 2, length: 0))
        view.insertText("か")
        XCTAssertEqual(recorder.events, [.text("か")])
        XCTAssertNil(view.markedTextRange)
    }

    func testDeleteDuringCompositionOnlyEditsTheCandidate() {
        let recorder = Recorder()
        let view = makeView(recorder)
        view.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0))
        view.deleteBackward()
        // UIKit may discard the entire provisional candidate on Delete. Its native
        // composition behavior is authoritative; no remote backspace may escape.
        XCTAssertTrue(recorder.events.isEmpty)
        let remainingCandidate = view.text ?? ""
        view.unmarkText()
        XCTAssertEqual(recorder.events, remainingCandidate.isEmpty ? [] : [.text(remainingCandidate)])
        view.deleteBackward()
        XCTAssertEqual(recorder.events.last, .key("backspace"))
    }

    func testControlLossDiscardsCompositionAndCannotReplayItAfterReenable() {
        let recorder = Recorder()
        let token = UUID()
        let view = makeView(recorder, focusRequest: token)
        view.setMarkedText("pending", selectedRange: NSRange(location: 7, length: 0))
        configure(view, recorder: recorder, isEnabled: false, focusRequest: token)
        view.unmarkText()
        view.insertText("blocked")
        view.deleteBackward()
        XCTAssertEqual(view.text, "")
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertFalse(view.canBecomeFirstResponder)
        configure(view, recorder: recorder, focusRequest: token)
        view.insertText("new")
        XCTAssertEqual(recorder.events, [.text("new")])
    }

    func testDismantledReceiverRejectsFurtherTypingAndCannotBeReconfigured() {
        let recorder = Recorder()
        let view = makeView(recorder)
        view.setMarkedText("pending", selectedRange: NSRange(location: 7, length: 0))
        RemoteKeyboardInput.dismantleUIView(view, coordinator: ())
        configure(view, recorder: recorder)
        view.insertText("late")
        view.unmarkText()
        view.deleteBackward()
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertEqual(view.text, "")
        XCTAssertFalse(view.canBecomeFirstResponder)
    }

    func testCommittedUnicodeIsAdmittedAsOneCompleteEdit() {
        let recorder = Recorder()
        let view = makeView(recorder)
        let committed = String(repeating: "👩🏽‍💻中文e\u{301}", count: 900)
        view.insertText(committed)
        let chunks = recorder.events.compactMap { event -> String? in
            if case .text(let text) = event { return text }
            return nil
        }
        XCTAssertEqual(chunks.count, 1, "Only the delivery queue splits an accepted edit.")
        XCTAssertEqual(chunks.joined(), committed)
        XCTAssertEqual(view.text, "")
    }

    func testRejectedTextRemainsAvailableWithoutSendingAnyFollowingKeys() {
        let recorder = Recorder()
        recorder.acceptsText = false
        let view = makeView(recorder)
        view.insertText("blocked\nnever")
        XCTAssertEqual(recorder.events, [.text("blocked\nnever")])
        XCTAssertEqual(view.text, "blocked\nnever", "A rejected edit is retained rather than erased.")
        XCTAssertFalse(recorder.events.contains(.key("return")))
    }

    func testHardwareCommandCannotOvertakeRejectedTextAndFlushesItFirst() throws {
        let recorder = Recorder()
        recorder.acceptsText = false
        let view = makeView(recorder)
        view.insertText("hello")
        let command = try XCTUnwrap(view.keyCommands?.first { $0.propertyList as? String == "left" })
        let action = try XCTUnwrap(command.action)
        _ = view.perform(action, with: command)
        XCTAssertFalse(recorder.events.contains(.key("left")))
        XCTAssertEqual(view.text, "hello")
        recorder.acceptsText = true
        recorder.events.removeAll()
        _ = view.perform(action, with: command)
        XCTAssertEqual(recorder.events, [.text("hello"), .key("left")])
        XCTAssertEqual(view.text, "")
    }

    func testPanelButtonsUseNativeOrderingAndLocalDeletion() {
        let recorder = Recorder()
        recorder.acceptsText = false
        let view = makeView(recorder)
        let commands = RemoteKeyboardCommands()
        commands.attach(view)
        view.insertText("hello")
        commands.send("cmd+a")
        XCTAssertFalse(recorder.events.contains(.key("cmd+a")))
        commands.send("backspace")
        XCTAssertEqual(view.text, "hell")
        XCTAssertFalse(recorder.events.contains(.key("backspace")))
        recorder.acceptsText = true
        recorder.events.removeAll()
        commands.send("tab")
        XCTAssertEqual(recorder.events, [.text("hell"), .key("tab")])
        commands.detach(view)
        commands.send("right")
        XCTAssertFalse(recorder.events.contains(.key("right")))
    }

    func testNativeKeyCommandActionsRouteCanonicalRemoteKeysWithoutLocalEdits() throws {
        let recorder = Recorder()
        let view = makeView(recorder)
        let commands = try XCTUnwrap(view.keyCommands)
        let expected: Set<String> = ["tab", "escape", "left", "right", "up", "down",
                                     "cmd+c", "cmd+v", "cmd+a", "cmd+z", "cmd+shift+z", "cmd+space"]
        XCTAssertEqual(Set(commands.compactMap { $0.propertyList as? String }), expected)
        XCTAssertTrue(expected.isSubset(of: DeskMessage.supportedKeys))
        for command in commands {
            let action = try XCTUnwrap(command.action)
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
            XCTAssertTrue(view.canPerformAction(action, withSender: command))
            _ = view.perform(action, with: command)
        }
        XCTAssertEqual(Set(recorder.events.compactMap { event -> String? in
            if case .key(let key) = event { return key }
            return nil
        }), expected)
        XCTAssertEqual(recorder.events.count, commands.count)
        XCTAssertEqual(view.text, "")
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
    }

    func testCommandCapturedBeforeCompositionCannotEscapeTheCompositionGate() throws {
        let recorder = Recorder()
        let view = makeView(recorder)
        let command = try XCTUnwrap(view.keyCommands?.first { $0.propertyList as? String == "left" })
        let action = try XCTUnwrap(command.action)
        view.setMarkedText("candidate", selectedRange: NSRange(location: 9, length: 0))
        XCTAssertFalse(view.canPerformAction(action, withSender: command))
        _ = view.perform(action, with: command)
        XCTAssertTrue(recorder.events.isEmpty)
        view.unmarkText()
        XCTAssertEqual(recorder.events, [.text("candidate")])
    }

    func testChangingDestinationDropsOldCompositionAndUsesCurrentCallbacks() {
        let first = Recorder(), second = Recorder()
        let view = makeView(first)
        view.setMarkedText("old", selectedRange: NSRange(location: 3, length: 0))
        configure(view, recorder: second, focusRequest: UUID())
        view.unmarkText()
        view.insertText("new")
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(second.events, [.text("new")])
    }

    func testFocusWaitsForKeyWindowAndAttemptsOncePerIntentionalRequest() async {
        let recorder = Recorder()
        let view = FocusProbe()
        let token = UUID()
        view.probeWindow.key = false
        configure(view, recorder: recorder, focusRequest: token)
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 0, "A view outside the key window cannot show the keyboard.")
        view.probeWindow.key = true
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: view.probeWindow)
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 1)
        for _ in 0..<5 { configure(view, recorder: recorder, focusRequest: token) }
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 1, "Fresh-frame view updates cannot keep requesting focus.")
        view.hasResponder = false
        configure(view, recorder: recorder, focusRequest: token)
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 1, "Voluntary focus loss remains lost for this request.")
        configure(view, recorder: recorder, focusRequest: UUID())
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 2)
        view.endInputSession()
    }

    func testRefusedFocusCanRetryOnALaterKeyWindowEventWithoutPolling() async {
        let recorder = Recorder(), view = FocusProbe()
        let token = UUID()
        view.acceptsFocus = false
        configure(view, recorder: recorder, focusRequest: token)
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 1)
        XCTAssertFalse(view.hasResponder)
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 1, "A refusal must not start a polling focus loop.")
        view.acceptsFocus = true
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: view.probeWindow)
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 2)
        XCTAssertTrue(view.hasResponder)
        configure(view, recorder: recorder, focusRequest: token)
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 2, "Successful focus consumes this opening intent.")
        view.endInputSession()
    }

    func testAvailabilityRecoveryRestoresOnlyAKeyboardItForcedToResign() async {
        let recorder = Recorder(), view = FocusProbe()
        let token = UUID()
        configure(view, recorder: recorder, focusRequest: token)
        await settleActor()
        XCTAssertTrue(view.hasResponder)
        configure(view, recorder: recorder, isEnabled: false, focusRequest: token)
        XCTAssertFalse(view.hasResponder)
        configure(view, recorder: recorder, focusRequest: token)
        await settleActor()
        XCTAssertTrue(view.hasResponder)
        XCTAssertEqual(view.focusAttempts, 2, "Freshness recovery restores the interrupted keyboard.")
        view.hasResponder = false // The wearer voluntarily dismissed it.
        configure(view, recorder: recorder, isEnabled: false, focusRequest: token)
        configure(view, recorder: recorder, focusRequest: token)
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 2, "Recovery must not reopen a voluntarily dismissed keyboard.")
        view.endInputSession()
    }

    func testDisabledOrDismissedPopoverCancelsQueuedFocusAndResigns() async {
        let recorder = Recorder()
        let view = FocusProbe()
        let token = UUID()
        configure(view, recorder: recorder, focusRequest: token)
        configure(view, recorder: recorder, isEnabled: false, focusRequest: token)
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 0, "An already-queued task must recheck permission.")
        configure(view, recorder: recorder, focusRequest: token)
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 1)
        let resignsBeforeDisable = view.resignAttempts
        configure(view, recorder: recorder, isEnabled: false, focusRequest: token)
        XCTAssertFalse(view.hasResponder)
        XCTAssertGreaterThan(view.resignAttempts, resignsBeforeDisable,
                             "Disabling releases focus; UIKit may also request its own resignations.")
        configure(view, recorder: recorder, focusRequest: UUID())
        view.endInputSession()
        await settleActor()
        XCTAssertEqual(view.focusAttempts, 1, "Dismantling must cancel an intentional queued refocus too.")
    }

    func testAttachedNativeKeyboardActuallyFocusesAndSurvivesRepeatedViewUpdates() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let view = RemoteKeyboardTextView()
        view.frame = CGRect(x: 20, y: 20, width: 400, height: 92)
        controller.view.addSubview(view)
        let recorder = Recorder()
        let token = UUID()
        defer {
            view.endInputSession()
            view.removeFromSuperview()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        configure(view, recorder: recorder, focusRequest: token)
        window.makeKeyAndVisible()
        for _ in 0..<30 {
            if view.isFirstResponder { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(view.isFirstResponder, "Opening the native receiver must actually focus the software keyboard.")
        for _ in 0..<4 {
            configure(view, recorder: recorder, focusRequest: token)
            await settleActor()
            XCTAssertTrue(view.isFirstResponder, "Periodic control-grant checks must not dismiss the keyboard.")
        }
        view.insertText("live 🙂")
        view.deleteBackward()
        view.insertText("\n")
        XCTAssertEqual(recorder.events, [.text("live 🙂"), .key("backspace"), .text("\n")])
        configure(view, recorder: recorder, isEnabled: false, focusRequest: token)
        XCTAssertFalse(view.isFirstResponder, "Control loss must dismiss the real native keyboard receiver.")
    }

    private func makeView(_ recorder: Recorder, focusRequest: UUID = UUID()) -> RemoteKeyboardTextView {
        let view = RemoteKeyboardTextView()
        configure(view, recorder: recorder, focusRequest: focusRequest)
        return view
    }

    private func configure(_ view: RemoteKeyboardTextView, recorder: Recorder,
                           isEnabled: Bool = true, focusRequest: UUID = UUID(), destinationID: UInt32? = nil) {
        view.configure(isEnabled: isEnabled, focusRequest: focusRequest, onText: { text in
            recorder.events.append(.text(text))
            return recorder.acceptsText
        }, onKey: { recorder.events.append(.key($0)) }, destinationID: destinationID)
    }

    private func settleActor() async {
        // Bounded actor turns let the production Task and its own yield finish, without
        // waiting on a physical keyboard, presentation animation or network.
        for _ in 0..<12 { await Task.yield() }
    }

    private enum Event: Equatable { case text(String), key(String) }

    private final class Recorder {
        var events: [Event] = []
        var acceptsText = true
    }

    private final class KeyWindowProbe: UIWindow {
        var key = true
        override var isKeyWindow: Bool { key }
    }

    private final class FocusProbe: RemoteKeyboardTextView {
        let probeWindow = KeyWindowProbe()
        var hasResponder = false
        var focusAttempts = 0
        var resignAttempts = 0
        var acceptsFocus = true
        override var window: UIWindow? { probeWindow }
        override var isFirstResponder: Bool { hasResponder }
        override func becomeFirstResponder() -> Bool {
            focusAttempts += 1
            guard acceptsFocus else { return false }
            hasResponder = true
            return true
        }
        override func resignFirstResponder() -> Bool {
            resignAttempts += 1
            hasResponder = false
            return true
        }
    }
}
