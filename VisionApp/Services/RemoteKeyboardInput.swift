import SwiftUI
import UIKit

/// A native live keyboard for the keyboard popover. The caller supplies the current scene,
/// connection, control and frame-freshness gate and keeps the final gate in its callbacks.
/// Renew `focusRequest` only for an intentional opening or refocus; view updates never renew
/// it. Committed text goes straight to the Mac rather than becoming a second local document.
@MainActor
struct RemoteKeyboardInput: UIViewRepresentable {
    let isEnabled: Bool
    let focusRequest: UUID
    let onText: (String) -> Bool
    let onKey: (String) -> Void
    var onCancel: () -> Void = {}
    var commands: RemoteKeyboardCommands? = nil
    var destinationID: UInt32? = nil

    func makeUIView(context: Context) -> RemoteKeyboardTextView {
        let view = RemoteKeyboardTextView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: RemoteKeyboardTextView, context: Context) {
        if view.commandRouter !== commands {
            view.commandRouter?.detach(view)
            view.commandRouter = commands
        }
        commands?.attach(view)
        view.configure(isEnabled: isEnabled, focusRequest: focusRequest,
                       onText: onText, onKey: onKey, onCancel: onCancel,
                       destinationID: destinationID)
    }

    static func dismantleUIView(_ view: RemoteKeyboardTextView, coordinator: ()) {
        view.commandRouter?.detach(view)
        view.endInputSession()
    }
}

/// A panel's buttons use the same native receiver as hardware keys, so they cannot overtake
/// an edit that the delivery queue has not admitted. The receiver is never retained here.
@MainActor
final class RemoteKeyboardCommands: ObservableObject {
    private weak var receiver: RemoteKeyboardTextView?
    func attach(_ view: RemoteKeyboardTextView) { receiver = view }
    func detach(_ view: RemoteKeyboardTextView) {
        if receiver === view { receiver = nil }
    }
    func send(_ key: String) { receiver?.sendRemoteKey(key) }
    func retryRemainingText() { receiver?.retryRemainingText() }
}

/// `UITextView` owns marked text and keyboard layout handling. In particular, no physical
/// `pressesBegan` handler also forwards characters: ordinary physical and software typing
/// reach the same `UITextInput` path exactly once.
@MainActor
class RemoteKeyboardTextView: UITextView, UITextViewDelegate {
    weak var commandRouter: RemoteKeyboardCommands?
    private var inputIsEnabled = false
    private var inputHasEnded = false
    private var focusRequest: UUID?
    private var destinationID: UInt32?
    private var attemptedFocusRequest: UUID?
    private var pendingFocus: Task<Void, Never>?
    private var mutationDepth = 0
    private var onText: ((String) -> Bool)?
    private var onKey: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    private let placeholder = UILabel()

    private static let commands: [(input: String, modifiers: UIKeyModifierFlags, key: String)] = [
        ("\t", [], "tab"), (UIKeyCommand.inputEscape, [], "escape"),
        (UIKeyCommand.inputLeftArrow, [], "left"), (UIKeyCommand.inputRightArrow, [], "right"),
        (UIKeyCommand.inputUpArrow, [], "up"), (UIKeyCommand.inputDownArrow, [], "down"),
        ("c", .command, "cmd+c"), ("v", .command, "cmd+v"),
        ("a", .command, "cmd+a"), ("z", .command, "cmd+z"),
        ("z", [.command, .shift], "cmd+shift+z"), (" ", .command, "cmd+space")
    ]

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        isEditable = false
        isScrollEnabled = false
        borderStyle = .roundedRect
        font = .preferredFont(forTextStyle: .body)
        textColor = .label
        adjustsFontForContentSizeCategory = true
        textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textContainer.lineFragmentPadding = 0
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardType = .default
        returnKeyType = .default
        enablesReturnKeyAutomatically = false
        if #available(visionOS 2.4, *) { writingToolsBehavior = .none }
        accessibilityLabel = "Type directly on your Mac"
        accessibilityHint = "Text is sent immediately. Return and Delete act on your Mac."
        accessibilityIdentifier = "remote-keyboard-input"

        placeholder.text = "Type directly on your Mac"
        placeholder.font = font
        placeholder.textColor = .secondaryLabel
        placeholder.numberOfLines = 0
        placeholder.isAccessibilityElement = false
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor, constant: -12),
            placeholder.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor, constant: 12)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                              name: UIWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)),
                                              name: UIWindow.didResignKeyNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func configure(isEnabled: Bool, focusRequest: UUID,
                   onText: @escaping (String) -> Bool, onKey: @escaping (String) -> Void,
                   onCancel: @escaping () -> Void = {}, destinationID: UInt32? = nil) {
        guard !inputHasEnded else { return }
        let destinationChanged = self.destinationID != destinationID
        let refocusing = self.focusRequest != nil && self.focusRequest != focusRequest
        if destinationChanged || refocusing {
            pendingFocus?.cancel()
            pendingFocus = nil
            // Refocusing the same explicit destination must not erase a committed edit that
            // the delivery queue rejected. Compositions and unknown/changed destinations
            // remain cancellation boundaries; accepted operations are never replayed here.
            if destinationChanged || destinationID == nil || markedTextRange != nil {
                self.onCancel?()
                cancelComposition()
            }
        }
        self.focusRequest = focusRequest
        self.destinationID = destinationID
        self.onText = onText
        self.onKey = onKey
        self.onCancel = onCancel
        // UIKit may resign automatically when editability changes. Capture the active
        // keyboard before that mutation so a forced interruption retains its intent.
        let wasFirstResponder = isFirstResponder
        if inputIsEnabled && !isEnabled { self.onCancel?() }
        inputIsEnabled = isEnabled
        isEditable = isEnabled
        if isEnabled {
            scheduleFocusIfNeeded()
        } else {
            pendingFocus?.cancel()
            pendingFocus = nil
            // Resigning can itself commit marked text. Disable routing before asking UIKit
            // to resign, and discard it rather than replay it if control becomes available.
            if wasFirstResponder {
                // This component interrupted an active keyboard, rather than the wearer
                // dismissing it. Restore that intent when the live gate becomes available.
                attemptedFocusRequest = nil
                if isFirstResponder { resignFirstResponder() }
            }
            cancelComposition()
        }
    }

    func endInputSession() {
        onCancel?()
        inputHasEnded = true
        inputIsEnabled = false
        pendingFocus?.cancel()
        pendingFocus = nil
        if isFirstResponder { resignFirstResponder() }
        cancelComposition()
        isEditable = false
        onText = nil
        onKey = nil
        onCancel = nil
        NotificationCenter.default.removeObserver(self)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onCancel?() }
        return resigned
    }

    override var canBecomeFirstResponder: Bool {
        inputIsEnabled && !inputHasEnded && super.canBecomeFirstResponder
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            onCancel?()
            pendingFocus?.cancel()
            pendingFocus = nil
            cancelComposition()
        } else {
            scheduleFocusIfNeeded()
        }
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let changedWindow = notification.object as? UIWindow,
              changedWindow === window else { return }
        scheduleFocusIfNeeded()
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        guard let changedWindow = notification.object as? UIWindow,
              changedWindow === window else { return }
        onCancel?()
        cancelComposition()
    }

    private func scheduleFocusIfNeeded() {
        guard inputIsEnabled, !inputHasEnded, window != nil,
              let request = focusRequest, request != attemptedFocusRequest, pendingFocus == nil else { return }
        pendingFocus = Task { @MainActor [weak self] in
            // Popover construction can attach the view before presentation finishes. Wait
            // until the next actor turn; a later key-window notification covers attachment
            // to a window that is not active yet.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.pendingFocus = nil
            guard self.inputIsEnabled, !self.inputHasEnded,
                  self.focusRequest == request, self.window?.isKeyWindow == true,
                  self.attemptedFocusRequest != request else { return }
            // UIKit can refuse during presentation. Consume the intent only on success;
            // a later configure/key-window event may retry, without a polling focus loop.
            if self.isFirstResponder || self.becomeFirstResponder() {
                self.attemptedFocusRequest = request
            }
        }
    }

    override func insertText(_ text: String) {
        guard inputIsEnabled, !inputHasEnded else { return }
        mutationDepth += 1
        super.insertText(text)
        mutationDepth -= 1
        forwardCommittedText()
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard inputIsEnabled, !inputHasEnded else { return }
        mutationDepth += 1
        super.setMarkedText(markedText, selectedRange: selectedRange)
        mutationDepth -= 1
        updatePlaceholder()
        // `nil` can finish an input method's composition, while an empty marked string is
        // still provisional. `markedTextRange` remains the authority for the distinction.
        if markedText == nil { forwardCommittedText() }
    }

    override func unmarkText() {
        mutationDepth += 1
        super.unmarkText()
        mutationDepth -= 1
        forwardCommittedText()
    }

    override func replace(_ range: UITextRange, withText text: String) {
        guard inputIsEnabled, !inputHasEnded else { return }
        mutationDepth += 1
        super.replace(range, withText: text)
        mutationDepth -= 1
        forwardCommittedText()
    }

    override func deleteBackward() {
        guard inputIsEnabled, !inputHasEnded else { return }
        if markedTextRange != nil || !(text ?? "").isEmpty {
            // Deleting a composing character edits the native candidate, not the Mac.
            mutationDepth += 1
            super.deleteBackward()
            mutationDepth -= 1
            forwardCommittedText()
        } else {
            onKey?("backspace")
        }
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        inputIsEnabled && !inputHasEnded
    }

    func textViewDidChange(_ textView: UITextView) { forwardCommittedText() }

    private func forwardCommittedText() {
        updatePlaceholder()
        guard mutationDepth == 0, inputIsEnabled, !inputHasEnded,
              markedTextRange == nil, let committed = text, !committed.isEmpty else { return }
        // The delivery queue accepts the entire edit or none of it. Retain rejected text so
        // a full queue or unavailable companion cannot silently erase the wearer's paste.
        mutationDepth += 1
        let accepted = onText?(committed) == true
        mutationDepth -= 1
        if accepted { clearLocalText() }
    }

    /// An explicit button action, never called from a SwiftUI view-update callback.
    /// Only the locally retained, not-yet-admitted edit is eligible for another attempt.
    func retryRemainingText() { forwardCommittedText() }

    override var keyCommands: [UIKeyCommand]? {
        guard inputIsEnabled, !inputHasEnded else { return [] }
        // Candidate selection keys belong to the input method until it commits. Return and
        // Backspace always use UIKit's text-input path, avoiding duplicate hardware input.
        guard markedTextRange == nil else { return super.keyCommands }
        return Self.commands.map { definition in
            let command = UIKeyCommand(title: definition.key, action: #selector(relayCommand(_:)),
                                       input: definition.input, modifierFlags: definition.modifiers,
                                       propertyList: definition.key)
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticMirroring = false
            return command
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // No local copy/paste/select-all menu: its clipboard and selection would act on the
        // empty keyboard sink instead of the remote focused application.
        action == #selector(relayCommand(_:)) && inputIsEnabled && !inputHasEnded && markedTextRange == nil
    }

    @objc private func relayCommand(_ command: UIKeyCommand) {
        guard inputIsEnabled, !inputHasEnded, markedTextRange == nil,
              let definition = Self.commands.first(where: {
                  $0.input == command.input && $0.modifiers == command.modifierFlags
              }) else { return }
        sendRemoteKey(definition.key)
    }

    func sendRemoteKey(_ key: String) {
        guard inputIsEnabled, !inputHasEnded else { return }
        // These two keys edit a local candidate or retained edit before acting on the Mac,
        // exactly like UIKit's physical and software text-input paths.
        if key == "backspace" { deleteBackward(); return }
        if key == "return" { insertText("\n"); return }
        guard markedTextRange == nil, Self.commands.contains(where: { $0.key == key }) else { return }
        let destination = focusRequest
        forwardCommittedText()
        guard inputIsEnabled, !inputHasEnded, focusRequest == destination,
              markedTextRange == nil, (text ?? "").isEmpty else { return }
        onKey?(key)
    }

    private func cancelComposition() {
        mutationDepth += 1
        super.unmarkText()
        text = ""
        mutationDepth -= 1
        updatePlaceholder()
    }

    private func clearLocalText() {
        mutationDepth += 1
        text = ""
        mutationDepth -= 1
        updatePlaceholder()
    }

    private func updatePlaceholder() { placeholder.isHidden = !(text ?? "").isEmpty }
}
