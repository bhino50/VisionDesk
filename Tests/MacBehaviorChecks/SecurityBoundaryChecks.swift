import AppKit
import DeskCore
import DeskTransport
import Foundation

@MainActor
func runSecurityBoundaryChecks(_ runner: CheckRunner) async {
    await runner.check("Remote Stop intent survives preferences and a new model until deliberate resume") {
        let suite = "VisionDesk.SecurityChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = PairingKey.generate()
        let available = HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false)
        @MainActor func model(_ configuration: RemoteHostConfiguration) -> CompanionModel {
            CompanionModel(saveLANConfiguration: { _ in }, remoteConfiguration: configuration, localAddresses: checkLocalAddresses,
                           loadRemoteKey: { key }, saveRemoteConfiguration: { $0.save(to: defaults) },
                           contentProvider: { throw CheckError.preparationAbandoned },
                           inventory: { [syntheticDisplay(1)] }, liveSession: { available },
                           keepAwake: KeepAwakeRecorder().hold, screenCaptureAccess: { true }, controlAccess: controlAccess(true))
        }
        @MainActor func attach(_ host: CompanionModel) {
            host.sharing = true
            host.attach(DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: 1), key: key))
            host.receive(DeskMessage(kind: "heartbeat"))
        }
        for peerStop in [false, true] {
            let initial = model(RemoteHostConfiguration(enabled: true, address: "100.64.0.1:58271", allowControl: true, keepAwake: false))
            attach(initial)
            initial.enableInput()
            if peerStop { initial.receive(DeskMessage(kind: "stop")) } else { initial.revoke() }
            let saved = RemoteHostConfiguration.load(from: defaults)
            runner.expect(peerStop ? saved.peerPaused : saved.ownerPaused, "the exact Stop intent is persisted")
            initial.stop()
            let restarted = model(saved)
            restarted.startSavedHosting()
            attach(restarted)
            runner.expect(!restarted.controlEnabled, "saved reconnect plus heartbeat cannot erase Stop")
            restarted.receive(DeskMessage(kind: "requestControl"))
            runner.expectEqual(restarted.controlEnabled, peerStop, "peer Resume is allowed only if the owner did not pause")
            restarted.enableInput()
            let resumed = RemoteHostConfiguration.load(from: defaults)
            runner.expect(!resumed.ownerPaused && !resumed.peerPaused && restarted.controlEnabled, "explicit owner Enable clears and saves both pauses")
            restarted.stop()
        }
    }

    await runner.check("Remote address edits retain both Stop decisions") {
        for peerStop in [false, true] {
            let gate = PreparationGate()
            let key = PairingKey.generate()
            var saved = RemoteHostConfiguration.disabled
            let original = RemoteHostConfiguration(enabled: true, address: "100.64.0.1:58271", allowControl: true,
                                                   keepAwake: false, ownerPaused: !peerStop, peerPaused: peerStop)
            let host = CompanionModel(saveLANConfiguration: { _ in }, remoteConfiguration: original, localAddresses: { ["100.64.0.1", "100.64.0.2"] },
                loadRemoteKey: { key }, saveRemoteConfiguration: { saved = $0 },
                contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                inventory: { [syntheticDisplay(1)] },
                liveSession: { HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false) },
                keepAwake: KeepAwakeRecorder().hold, screenCaptureAccess: { true }, controlAccess: controlAccess(true))
            runner.expectEqual(host.configureRemoteAccess(address: "100.64.0.2", allowControl: true, keepAwake: false), .restarted,
                               "address edit uses the legitimate owner configuration flow")
            runner.expect(saved.ownerPaused == !peerStop && saved.peerPaused == peerStop,
                          "moving the listener cannot renew revoked input consent")
            host.attach(DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: 1), key: key))
            host.receive(DeskMessage(kind: "heartbeat"))
            runner.expect(!host.controlEnabled, "reconnecting to the new address stays view only")
            host.stop(); gate.release()
        }
    }

    await runner.check("Disabling remote mode restores the nearby host's saved Stop decisions") {
        for peerStop in [false, true] {
            let lan = LANHostConfiguration(enabled: true, allowControl: true, ownerPaused: !peerStop, peerPaused: peerStop)
            let host = CompanionModel(lanConfiguration: lan, saveLANConfiguration: { _ in },
                remoteConfiguration: checkRemoteConfiguration, deleteRemoteKey: {}, saveRemoteConfiguration: { _ in },
                inventory: { [syntheticDisplay(1)] },
                liveSession: { HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false) },
                keepAwake: KeepAwakeRecorder().hold, screenCaptureAccess: { true }, controlAccess: controlAccess(true))
            host.disableRemoteAccess()
            runner.expect(!host.remoteConfiguration.enabled, "the remote host is disabled")
            host.sharing = true
            host.attach(DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: 1), key: PairingKey.generate()))
            host.receive(DeskMessage(kind: "heartbeat"))
            runner.expect(!host.controlEnabled, "nearby reconnect cannot inherit remote consent after either nearby Stop")
            host.stop()
        }
    }

    await runner.check("Generated event budget bounds maximum text bursts and always permits drag release") {
        var events: [CGEvent] = []
        var now = 10.0
        let output = InputOutput(permission: controlAccess(true), eventSink: { events.append($0) },
                                 displayBounds: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) }, uptime: { now })
        let maximumText = DeskMessage(kind: "input", displayID: 1, action: "text", text: String(repeating: "a", count: 4096))
        runner.expect(maximumText.isValid, "exploit-sized packet is protocol-valid")
        output.apply(DeskMessage(kind: "input", displayID: 1, x: 0.5, y: 0.5, action: "leftDown"))
        output.apply(maximumText)
        let accepted = events.count
        runner.expectEqual(accepted, 412, "one legitimate full paste plus down fits the work budget")
        for _ in 0..<240 { output.apply(maximumText) }
        runner.expectEqual(events.count, accepted, "repeated valid large packets post no partial text")
        output.apply(DeskMessage(kind: "input", displayID: 1, x: 0.5, y: 0.5, action: "leftUp"))
        runner.expectEqual(events.last?.type, .leftMouseUp, "budget exhaustion cannot strand a held button")
        runner.expectEqual(events.count, accepted + 1, "exactly the safety release is posted")
        now += 1
        let unicode = "Hello 👨‍👩‍👧‍👦 — café 🇺🇸"
        let before = events.count
        output.apply(DeskMessage(kind: "input", displayID: 1, action: "text", text: unicode))
        runner.expect(events.count > before, "normal Unicode typing resumes after budget refill")
        var units: [UInt16] = []
        for event in events[before...] where event.type == .keyDown {
            var length = 0
            var buffer = [UInt16](repeating: 0, count: 64)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
            units.append(contentsOf: buffer.prefix(length))
        }
        runner.expectEqual(String(decoding: units, as: UTF16.self), unicode, "posted Unicode preserves complete original text")
    }

    await runner.check("Initially sleeping displays block capture before preparation and waking permits recovery") {
        var observation = HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: true)
        var keyLoads = 0
        let gate = PreparationGate()
        let host = CompanionModel(saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses,
                                  loadRemoteKey: { keyLoads += 1; return PairingKey.generate() },
                                  saveRemoteConfiguration: { _ in },
                                  contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                  inventory: { [syntheticDisplay(1)] }, liveSession: { observation },
                                  keepAwake: KeepAwakeRecorder().hold, screenCaptureAccess: { true }, controlAccess: controlAccess(false))
        host.startSavedHosting()
        runner.expect(host.hostSession.screensAsleep && !host.busy && !host.sharing && keyLoads == 0 && !gate.wasEntered,
                      "sleep is seeded at initialization and blocks even key/capture preparation")
        observation.displaysAsleep = false
        host.receiveSessionNotice(.screensWoke)
        runner.expect(host.restartPending, "normal wake schedules the authorized saved host")
        host.stop()
        gate.release()
    }

    await runner.check("Launch argument cannot grant remote access but saved hosting still starts") {
        var saves = 0
        let gate = PreparationGate()
        let host = CompanionModel(loadLANKey: { nil }, saveLANKey: { _ in saves += 1 }, saveLANConfiguration: { _ in saves += 1 },
                                  localAddresses: checkLocalAddresses, loadRemoteKey: { nil }, saveRemoteKey: { _ in saves += 1 },
                                  saveRemoteConfiguration: { _ in saves += 1 },
                                  contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                  inventory: { [syntheticDisplay(1)] },
                                  liveSession: { HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false) },
                                  keepAwake: KeepAwakeRecorder().hold, screenCaptureAccess: { true }, controlAccess: controlAccess(true))
        let lifecycle = CompanionWindowLifecycle(activate: {})
        _ = lifecycle.windowAppeared(host, arguments: ["app", "--enable-remote-host", "100.64.0.1"])
        runner.expect(saves == 0 && !host.remoteConfiguration.enabled && !host.busy && !host.sharing && !gate.wasEntered,
                      "fresh command-line launch grants nothing and starts nothing")
        host.adoptRemoteConfiguration(checkRemoteConfiguration)
        // A saved host attempts its ordinary key validation, proving startup remains enabled.
        let second = CompanionWindowLifecycle(activate: {})
        _ = second.windowAppeared(host, arguments: [])
        runner.expect(host.status.contains("pairing key is missing"), "saved startup still runs legitimate preflight")
        host.stop(); gate.release()
    }
}
