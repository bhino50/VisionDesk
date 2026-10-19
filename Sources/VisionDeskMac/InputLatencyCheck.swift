import AppKit
import DeskCore
import DeskTransport
import Network

/// Opt-in diagnostic that targets only its own window. Receipt in AppKit, rather than
/// successful CGEvent construction, is the measured endpoint. Text and navigation keys are
/// sent only to this diagnostic’s focused view; no global shortcuts or clipboard operations.
@MainActor
final class InputLatencyCheck {
    private final class ProbeView: NSView {
        static let sourceTag: Int64 = 0x5644_5052_4F42_45
        var expectedTag: Int64 = sourceTag
        var expectedClickCount: Int?
        var expectedText: String?
        var expectedKeyCode: UInt16?
        var expected: NSEvent.EventType?
        var postedAt: TimeInterval = 0
        var delay: TimeInterval?
        var buttonActivations = 0
        @objc func activateProbeButton(_ sender: NSButton) {
            guard NSApp.currentEvent?.cgEvent?.getIntegerValueField(.eventSourceUserData) == expectedTag else { return }
            buttonActivations += 1
        }
        override var acceptsFirstResponder: Bool { true }
        override func updateTrackingAreas() {
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
            super.updateTrackingAreas()
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
            let message = "VisionDesk input check\nTesting pointer, scroll and typing inside this window."
            (message as NSString).draw(in: bounds.insetBy(dx: 30, dy: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 21)])
        }
        private func received(_ event: NSEvent) {
            guard event.type == expected,
                  event.cgEvent?.getIntegerValueField(.eventSourceUserData) == expectedTag,
                  expectedClickCount == nil || event.clickCount == expectedClickCount else { return }
            if event.type == .keyDown {
                if let text = expectedText,
                   event.characters?.precomposedStringWithCanonicalMapping != text.precomposedStringWithCanonicalMapping { return }
                if let code = expectedKeyCode, event.keyCode != code { return }
                let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
                guard event.modifierFlags.intersection(modifiers).isEmpty else { return }
            }
            delay = ProcessInfo.processInfo.systemUptime - postedAt
            expected = nil
        }
        override func mouseMoved(with event: NSEvent) { received(event) }
        override func mouseDown(with event: NSEvent) { received(event) }
        override func mouseUp(with event: NSEvent) { received(event) }
        override func mouseDragged(with event: NSEvent) { received(event) }
        override func rightMouseDown(with event: NSEvent) { received(event) }
        override func rightMouseUp(with event: NSEvent) { received(event) }
        override func scrollWheel(with event: NSEvent) { received(event) }
        override func keyDown(with event: NSEvent) { received(event) }
    }

    func run() async {
        let input = InputOutput(diagnosticTag: ProbeView.sourceTag)
        guard input.hasPermission, let screen = NSScreen.main,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
              let primary = NSScreen.screens.first else {
            write(["success": false, "reason": "Mac control permission and an available display are required."])
            return
        }
        let window = NSWindow(contentRect: CGRect(x: screen.visibleFrame.midX - 320, y: screen.visibleFrame.midY - 180, width: 640, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "VisionDesk · Input latency check"
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        let view = ProbeView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        let button = NSButton(title: "Click check", target: view, action: #selector(ProbeView.activateProbeButton(_:)))
        button.frame = CGRect(x: 450, y: 50, width: 160, height: 44)
        button.bezelStyle = .rounded
        view.addSubview(button)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        defer { input.release(); window.close() }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let server = DeskServer()
        let key = PairingKey.generate()
        var peer: DeskConnection?
        var postingAttempts = 0
        var buttonFixtureActive = false
        var pendingButtonDown: DeskMessage?
        server.onConnection = { channel in
            peer = channel
            channel.onMessage = { message in
                if message.kind == "input", window.isKeyWindow, window.isVisible,
                   (window.firstResponder === view || window.firstResponder === button), input.hasPermission {
                    input.setDiagnosticTag(view.expectedTag)
                    if buttonFixtureActive {
                        // A button in THIS process enters AppKit's tracking loop on down.
                        // Submit the completed pair in one actor turn so the diagnostic's
                        // own UI cannot block delivery of the up callback. Normal pointer
                        // and keyboard fixtures above still post each packet separately.
                        if message.action == "leftDown" { pendingButtonDown = message; return }
                        if message.action == "leftUp", let down = pendingButtonDown {
                            pendingButtonDown = nil
                            postingAttempts += 2
                            input.apply(down)
                            input.apply(message)
                        }
                        return
                    }
                    postingAttempts += 1
                    input.apply(message)
                }
            }
        }
        do { try server.start(key: key, name: "Input probe", bindHost: "127.0.0.1") }
        catch { write(["success": false, "reason": "Could not start isolated test transport."]); return }
        defer { server.stop() }
        for _ in 0..<200 {
            if server.port != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard let port = server.port, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            write(["success": false, "reason": "Isolated transport did not bind."]); return
        }
        let client = DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: endpointPort), key: key)
        var linked = false
        client.onState = { if $0 == .ready { linked = true } }
        client.start()
        defer { client.cancel() }
        for _ in 0..<400 {
            if linked && peer != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard linked, peer != nil else {
            write(["success": false, "reason": "Isolated TLS pairing did not complete."]); return
        }
        client.send(DeskMessage(kind: "capabilities", videoCodec: DeskMessage.supportedVideoCodec))
        // Four synthetic screen payloads exercise the production wire codec concurrently.
        // This tests input receipt under transport load, not four physical captures/decoders.
        var screenFrames = 0
        let payload = Data(repeating: 0xA5, count: 24_000)
        let screenLoad = Task { @MainActor in
            while !Task.isCancelled {
                for display in 1...4 {
                    if peer?.send(DeskMessage(kind: "frame", displayID: UInt32(display), jpeg: payload)) == true { screenFrames += 1 }
                }
                do { try await Task.sleep(nanoseconds: 33_333_333) } catch { return }
            }
        }
        defer { screenLoad.cancel() }
        let bounds = CGDisplayBounds(id)
        var samples: [[String: Any]] = []
        var failed = false
        // All points lie in the probe content. Suspend between posts so AppKit can deliver
        // each event. Focus is rechecked immediately before posting; if focus changes during
        // OS delivery, the missing tagged receipt fails the check rather than claiming success.
        let actions: [(String, NSEvent.EventType)] = [("move", .mouseMoved), ("leftDown", .leftMouseDown)]
            + Array(repeating: ("move", .leftMouseDragged), count: 60)
            + [("leftUp", .leftMouseUp)]
            + Array(repeating: ("scroll", .scrollWheel), count: 40)
            + Array(repeating: ("rightClick", .rightMouseUp), count: 10)
            + Array(repeating: ("doubleClick", .leftMouseUp), count: 10)
            + Array(repeating: ("move", .mouseMoved), count: 5)
        for (index, item) in actions.enumerated() {
            guard window.isKeyWindow, window.isVisible else { failed = true; break }
            let local = CGPoint(x: 220 + Double(index % 60), y: 180)
            let appKitPoint = window.convertPoint(toScreen: view.convert(local, to: nil))
            let point = CGPoint(x: appKitPoint.x, y: primary.frame.maxY - appKitPoint.y)
            guard bounds.contains(point) else { failed = true; break }
            let message = DeskMessage(kind: "input", displayID: id,
                                      x: (point.x - bounds.minX) / (bounds.width - 1),
                                      y: (point.y - bounds.minY) / (bounds.height - 1), action: item.0,
                                      deltaX: item.0 == "scroll" ? 0 : nil, deltaY: item.0 == "scroll" ? 3 : nil)
            view.delay = nil; view.expected = item.1
            view.expectedTag = ProbeView.sourceTag + Int64(index)
            view.expectedClickCount = item.0 == "doubleClick" ? 2 : nil
            view.postedAt = ProcessInfo.processInfo.systemUptime
            guard client.send(message) else { failed = true; break }
            for _ in 0..<200 {
                if view.delay != nil { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let delay = view.delay else { failed = true; break }
            samples.append(["action": item.0, "receiptMilliseconds": delay * 1_000])
            try? await Task.sleep(nanoseconds: 17_000_000)
        }
        // The key window is rechecked before every post and during the receipt wait. Only
        // tagged keyDowns with matching characters/keycodes and no modifiers count as receipt.
        let keyboard: [(action: String, text: String, characters: String?, code: UInt16?)] = [
            ("text", "VisionDesk", "VisionDesk", nil),
            ("text", "é", "é", nil), ("text", "🙂", "🙂", nil),
            ("text", "Ω", "Ω", nil), ("text", "漢", "漢", nil),
            ("text", "e\u{0301}", "e\u{0301}", nil),
            ("key", "return", nil, 36), ("key", "backspace", nil, 51),
            ("key", "tab", nil, 48), ("key", "left", nil, 123), ("key", "right", nil, 124)
        ]
        var keyboardSamples: [[String: Any]] = []
        if !failed {
            for (index, item) in keyboard.enumerated() {
                guard window.isKeyWindow, window.isVisible, window.firstResponder === view else { failed = true; break }
                view.expected = .keyDown
                view.expectedText = item.characters
                view.expectedKeyCode = item.code
                view.expectedTag = ProbeView.sourceTag + 10_000 + Int64(index)
                view.expectedClickCount = nil
                view.delay = nil
                view.postedAt = ProcessInfo.processInfo.systemUptime
                guard client.send(DeskMessage(kind: "input", displayID: id, action: item.action, text: item.text)) else { failed = true; break }
                for _ in 0..<200 {
                    guard window.isKeyWindow, window.isVisible, window.firstResponder === view else { failed = true; break }
                    if view.delay != nil { break }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                guard !failed, let delay = view.delay else { failed = true; break }
                keyboardSamples.append(["action": item.action, "receiptMilliseconds": delay * 1_000])
                try? await Task.sleep(nanoseconds: 17_000_000)
            }
        }
        // Verify a real AppKit control action, not only mouse event construction/receipt.
        // Each down/up pair targets this owned button and is submitted together before
        // AppKit's button-tracking loop begins. User hardware clicks cannot count as ours.
        let buttonChecks = 20
        buttonFixtureActive = true
        if !failed {
            for index in 0..<buttonChecks {
                guard window.isKeyWindow, window.isVisible else { failed = true; break }
                let local = CGPoint(x: button.frame.midX, y: button.frame.midY)
                let appKitPoint = window.convertPoint(toScreen: view.convert(local, to: nil))
                let point = CGPoint(x: appKitPoint.x, y: primary.frame.maxY - appKitPoint.y)
                guard bounds.contains(point) else { failed = true; break }
                view.expectedTag = ProbeView.sourceTag + 20_000 + Int64(index)
                let before = view.buttonActivations
                for action in ["leftDown", "leftUp"] {
                    guard client.send(DeskMessage(kind: "input", displayID: id,
                        x: (point.x - bounds.minX) / (bounds.width - 1),
                        y: (point.y - bounds.minY) / (bounds.height - 1), action: action)) else { failed = true; break }
                }
                guard !failed else { break }
                for _ in 0..<200 {
                    guard window.isKeyWindow, window.isVisible else { failed = true; break }
                    if view.buttonActivations > before { break }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                guard !failed, view.buttonActivations == before + 1 else { failed = true; break }
                try? await Task.sleep(nanoseconds: 17_000_000)
            }
        }
        let values = samples.compactMap { $0["receiptMilliseconds"] as? Double }.sorted()
        write(["success": !failed && samples.count == actions.count && keyboardSamples.count == keyboard.count && view.buttonActivations == buttonChecks, "expectedEvents": actions.count,
               "receivedEvents": samples.count, "inputPostingAttempted": postingAttempts > 0, "target": "diagnostic window only",
               "concurrentSyntheticScreenFrames": screenFrames,
               "negotiatedBinaryWireFormat": client.isUsingBinaryWireFormat && peer?.isUsingBinaryWireFormat == true,
               "medianMilliseconds": values.isEmpty ? NSNull() : values[values.count / 2] as Any,
               "p95Milliseconds": values.isEmpty ? NSNull() : values[min(values.count - 1, Int(Double(values.count) * 0.95))] as Any,
               "samples": samples, "keyboardExpectedEvents": keyboard.count,
               "keyboardReceivedEvents": keyboardSamples.count, "keyboardSamples": keyboardSamples,
               "buttonExpectedActivations": buttonChecks, "buttonReceivedActivations": view.buttonActivations,
               "buttonPairsPostedInOneActorTurn": true,
               "physicalHeadsetMeasured": false,
               "scope": "production TLS loopback and InputOutput.apply to AppKit receipt under four synthetic screen streams; excludes offsite network, headset decode/render and hand recognition"])
    }

    private func write(_ report: [String: Any]) {
        var report = report
        report["timestamp"] = ISO8601DateFormatter().string(from: Date())
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("input-latency-check.json")
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
        catch { NSLog("Input check report could not be saved: %@", error.localizedDescription) }
    }
}
