import Foundation
import DeskCore

/// Bounded, ordered keyboard delivery. Only an explicit zero-work "busy" reply is retried.
/// A transport failure or missing acknowledgement is ambiguous, so remaining input is discarded.
@MainActor
final class KeyboardDelivery {
    var send: (DeskMessage) -> Bool = { _ in false }
    var canControl: (UInt32) -> Bool = { _ in false }
    var onFailure: (String) -> Void = { _ in }
    var onAccepted: () -> Void = {}
    var onPendingChanged: (Int) -> Void = { _ in }
    private(set) var isSupported = false
    private(set) var pendingCount = 0
    private var queue: [DeskMessage] = []
    private var inFlight: DeskMessage?
    private var timeout: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var generation = UUID()
    private var busyCount = 0
    private var target: UInt32?
    static let maximumBytes = 32_768
    static let maximumOperations = 256

    func enable() { isSupported = true }

    @discardableResult
    func enqueueText(_ text: String, displayID: UInt32) -> Bool {
        guard !text.isEmpty else { return false }
        guard text.utf8.count <= Self.maximumBytes else {
            onFailure("Paste is too large. Send at most 32 KB at a time."); return false
        }
        var messages: [DeskMessage] = []
        var chunk = ""
        func flush() {
            if !chunk.isEmpty {
                messages.append(DeskMessage(kind: "input", displayID: displayID, action: "text", text: chunk))
                chunk = ""
            }
        }
        for character in text {
            let value = String(character)
            let key: String?
            switch value {
            case "\n", "\r", "\r\n": key = "return"
            case "\t": key = "tab"
            default: key = nil
            }
            if let key {
                flush()
                messages.append(DeskMessage(kind: "input", displayID: displayID, action: "key", text: key))
            } else {
                if value.utf8.count <= 512 {
                    if chunk.utf8.count + value.utf8.count > 512 { flush() }
                    chunk += value
                } else {
                    // Scalar boundaries keep pathological long graphemes inside the byte bound.
                    for scalar in value.unicodeScalars {
                        let part = String(scalar)
                        if chunk.utf8.count + part.utf8.count > 512 { flush() }
                        chunk += part
                    }
                }
            }
            if messages.count > Self.maximumOperations {
                onFailure("Paste has too many separate keyboard actions. Send a smaller part."); return false
            }
        }
        flush()
        return enqueue(messages, displayID: displayID)
    }

    @discardableResult
    func enqueueKey(_ key: String, displayID: UInt32) -> Bool {
        let message = DeskMessage(kind: "input", displayID: displayID, action: "key", text: key)
        guard message.isValid else { return false }
        return enqueue([message], displayID: displayID)
    }

    private func enqueue(_ messages: [DeskMessage], displayID: UInt32) -> Bool {
        guard isSupported else {
            onFailure("Update the Mac companion to use reliable keyboard input."); return false
        }
        guard canControl(displayID) else { cancel(); return false }
        if let target, target != displayID { cancel() }
        let old = queue + (inFlight.map { [$0] } ?? [])
        guard old.count + messages.count <= Self.maximumOperations,
              (old + messages).reduce(0, { $0 + ($1.text?.utf8.count ?? 0) }) <= Self.maximumBytes else {
            onFailure("Keyboard is still sending. Wait before entering more text."); return false
        }
        onAccepted()
        target = displayID
        queue.append(contentsOf: messages)
        updateCount()
        pump()
        return true
    }

    func receive(_ message: DeskMessage) {
        guard message.isValid, message.kind == "keyboardResult", let current = inFlight,
              message.keyboardRequestID == current.keyboardRequestID else { return }
        timeout?.cancel(); timeout = nil
        retry?.cancel(); retry = nil
        switch message.keyboardResult {
        case "posted":
            inFlight = nil; busyCount = 0
            updateCount(); pump()
        case "busy":
            // The host promises no events were posted. Keep this request ahead of later keys.
            busyCount += 1
            guard busyCount <= 30 else { fail("Mac input stayed busy. Remaining keyboard input was stopped."); return }
            let token = generation
            retry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.retry = nil
                self.transmit()
            }
        case "rejected": fail("Mac control rejected keyboard input. Remaining input was stopped.")
        default: fail("Keyboard delivery is uncertain. Check the Mac before typing again; input was not retried.")
        }
    }

    func validateAvailability() {
        if let target, pendingCount > 0, !canControl(target) { cancel() }
    }

    func cancel(endSession: Bool = false) {
        let hadPending = pendingCount > 0
        generation = UUID()
        timeout?.cancel(); timeout = nil
        retry?.cancel(); retry = nil
        queue.removeAll(); inFlight = nil; target = nil; busyCount = 0
        updateCount()
        if endSession { isSupported = false }
        if hadPending { onFailure("Keyboard input stopped after the destination changed. Check the Mac before continuing.") }
    }

    private func pump() {
        guard inFlight == nil, !queue.isEmpty else { return }
        var message = queue.removeFirst()
        message.keyboardRequestID = UUID().uuidString
        inFlight = message
        transmit()
    }

    private func transmit() {
        guard let message = inFlight, let display = message.displayID, canControl(display) else { cancel(); return }
        let token = generation
        // Install timeout first so a synchronous fake/transport callback cannot arm a stale timer.
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.generation == token,
                  self.inFlight?.keyboardRequestID == message.keyboardRequestID else { return }
            self.fail("Keyboard delivery is uncertain. Check the Mac before typing again; input was not retried.")
        }
        guard send(message) else {
            if generation == token { fail("Keyboard delivery is uncertain. Check the Mac before typing again; input was not retried.") }
            return
        }
    }

    private func updateCount() {
        pendingCount = queue.count + (inFlight == nil ? 0 : 1)
        onPendingChanged(pendingCount)
    }
    private func fail(_ reason: String) {
        cancel()
        onFailure(reason)
    }
}
