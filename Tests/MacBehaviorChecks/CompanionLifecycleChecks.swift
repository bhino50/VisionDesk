import AppKit
import Combine
import DeskCore
import DeskTransport
import Foundation
import Network

/// Lifecycle and input-gating behavior of the production `CompanionModel`.
/// Every check injects a content provider, so ScreenCaptureKit is never asked for content
/// and the screen-recording permission is never requested.
@MainActor
func runCompanionLifecycleChecks(_ runner: CheckRunner) async {
    await runner.check("Terminal or explicitly denied Keychain failures do not retry") {
        let errors: [PairingKeyStoreError] = [.notEntitled(errSecMissingEntitlement), .unreadableItem,
                                             .accessDenied(errSecUserCanceled), .accessDenied(errSecAuthFailed)]
        var loads = Array(repeating: 0, count: errors.count)
        var models: [CompanionModel] = []
        let configuration = RemoteHostConfiguration(enabled: true, address: "100.64.0.77:58271", allowControl: false, keepAwake: false)
        for (index, error) in errors.enumerated() {
            let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: configuration, localAddresses: checkLocalAddresses, loadRemoteKey: {
                loads[index] += 1; throw error
            }, contentProvider: {
                runner.expect(false, "terminal key error must not start capture")
                throw CheckError.preparationAbandoned
            })
            models.append(model)
            model.start()
        }
        try? await Task.sleep(nanoseconds: 2_300_000_000)
        runner.expectEqual(loads, Array(repeating: 1, count: errors.count), "no delayed restart or repeated access prompt")
        for model in models {
            runner.expect(!model.busy && !model.sharing, "terminal failures stay idle")
            model.stop()
        }
    }

    await runner.check("A transient Keychain failure retries before preparing capture") {
        var loads = 0, prepared = false
        let key = PairingKey.generate()
        let configuration = RemoteHostConfiguration(enabled: true, address: "100.64.0.77:58271", allowControl: false, keepAwake: false)
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: configuration, localAddresses: checkLocalAddresses, loadRemoteKey: {
            loads += 1
            if loads == 1 { throw CheckError.preparationAbandoned }
            return key
        }, contentProvider: {
            prepared = true
            throw CheckError.preparationAbandoned
        })
        model.start()
        runner.expect(!prepared, "failed key read must not start capture")
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !prepared && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        runner.expect(loads >= 2 && prepared, "a later successful key read must reach preparation automatically")
        model.stop()
    }

    await runner.check("A missing remote pairing key stops before capture preparation") {
        var prepared = false
        var loads = 0
        let configuration = RemoteHostConfiguration(enabled: true, address: "100.64.0.77:58271", allowControl: false, keepAwake: false)
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: configuration, localAddresses: checkLocalAddresses, loadRemoteKey: { loads += 1; return nil }, contentProvider: {
            prepared = true
            throw CheckError.preparationAbandoned
        })
        model.start()
        await drainMainActor()
        runner.expect(!prepared, "missing credentials must not start ScreenCaptureKit preparation")
        runner.expect(!model.busy && !model.sharing, "terminal configuration failure must remain idle")
        runner.expectEqual(model.status, "Remote pairing key is missing. Enable remote access again on this Mac.", "actionable repair message")
        runner.expectEqual(model.remoteConfiguration, configuration, "preserve settings for explicit repair")
        try? await Task.sleep(nanoseconds: 2_300_000_000)
        runner.expectEqual(loads, 1, "missing credentials must not restart after the first retry interval")
        model.stop()
    }

    await runner.check("An invalid remote address stops before loading a key or capture") {
        var loaded = false, prepared = false
        let configuration = RemoteHostConfiguration(enabled: true, address: "invalid", allowControl: false, keepAwake: false)
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: configuration, localAddresses: checkLocalAddresses, loadRemoteKey: {
            loaded = true; return nil
        }, contentProvider: {
            prepared = true; throw CheckError.preparationAbandoned
        })
        model.start()
        await drainMainActor()
        runner.expect(!loaded && !prepared, "invalid saved address must not touch credentials or capture")
        runner.expectEqual(model.status, "Remote host configuration is invalid. Enable remote access again.", "configuration error remains visible")
        runner.expect(!model.busy && !model.sharing, "no restart loop is started")
        model.stop()
    }

    await runner.check("Stop during asynchronous preparation abandons the session quietly") {
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: {
            await gate.waitUntilReleased()
            throw CheckError.preparationAbandoned
        })

        model.start()
        runner.expect(model.busy, "start must mark the companion busy")
        runner.expectEqual(model.status, "Preparing connected displays…", "status while preparing")
        runner.expect(!model.sharing, "sharing must stay false while preparing")

        await drainMainActor(rounds: 2)
        runner.expect(gate.wasEntered, "preparation must reach the injected content provider")

        model.stop()
        runner.expect(!model.busy, "stop must clear busy during preparation")
        runner.expect(!model.sharing, "stop must leave sharing false")
        runner.expectEqual(model.status, "Sharing stopped.", "status immediately after stop")

        // The abandoned preparation now fails. Its stale generation token must keep it from
        // overwriting the stopped state or reporting a failure the user did not cause.
        gate.release()
        await drainMainActor()
        runner.expectEqual(model.status, "Sharing stopped.", "abandoned preparation must not report a failure")
        runner.expect(!model.sharing, "abandoned preparation must not start sharing")
        runner.expect(!model.busy, "abandoned preparation must not leave the companion busy")
        runner.expect(!model.connected, "abandoned preparation must not report a connection")
        runner.expectEqual(model.pairingKey, "", "abandoned preparation must not publish a pairing key")
        runner.expect(!model.controlEnabled, "abandoned preparation must not enable control")
    }

    await runner.check("Enable input is refused while no headset is connected") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        model.enableInput()
        runner.expect(!model.controlEnabled, "control must stay off with no connection")
        runner.expectEqual(model.status, "Connect the headset before enabling input.", "refusal message")
    }

    await runner.check("Enable input is refused when the heartbeat is stale on a live link") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        // Linked, but no heartbeat has ever arrived, so the freshness window must refuse.
        model.connected = true
        model.enableInput()
        runner.expect(!model.controlEnabled, "a stale heartbeat must not enable control")
        runner.expectEqual(model.status, "Connect the headset before enabling input.", "refusal message")
    }

    await runner.check("Changing the input mode revokes control in both directions") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        runner.expect(!model.testMode, "real control must be the default")
        model.testMode = true

        model.controlEnabled = true
        model.testMode = false
        runner.expect(!model.controlEnabled, "leaving test mode must revoke control")
        runner.expectEqual(model.status, "Input mode changed. Enable it again on this Mac.", "revocation message")

        model.controlEnabled = true
        model.testMode = true
        runner.expect(!model.controlEnabled, "returning to test mode must revoke control")
        runner.expectEqual(model.status, "Input mode changed. Enable it again on this Mac.", "revocation message")

        // Assigning the same value must not churn the status or revoke again.
        model.status = "unchanged"
        model.testMode = true
        runner.expectEqual(model.status, "unchanged", "an unchanged mode must not revoke")
    }

    await runner.check("Stop resets sharing, control, pairing key and previews") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        model.sharing = true
        model.busy = true
        model.connected = true
        model.controlEnabled = true
        model.pairingKey = "0000-0000-0000-0000-0000-0000-0000-0000"
        model.previews = [1: NSImage(size: CGSize(width: 2, height: 2))]

        model.stop()
        runner.expect(!model.sharing, "stop must clear sharing")
        runner.expect(!model.busy, "stop must clear busy")
        runner.expect(!model.connected, "stop must clear the connection")
        runner.expect(!model.controlEnabled, "stop must revoke control")
        runner.expectEqual(model.pairingKey, "", "stop must clear the pairing key")
        runner.expect(model.previews.isEmpty, "stop must drop cached previews")
        runner.expectEqual(model.status, "Sharing stopped.", "status after stop")

        // Stop must stay idempotent so a second quit or sleep event cannot resurrect state.
        model.stop()
        runner.expect(!model.sharing && !model.busy && !model.connected, "a repeated stop must stay stopped")
    }

    await runner.check("Revoke releases control while leaving viewing available") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        model.sharing = true
        model.connected = true
        model.controlEnabled = true

        model.revoke()
        runner.expect(!model.controlEnabled, "revoke must release control")
        runner.expect(model.sharing, "revoke must not stop sharing")
        runner.expect(model.connected, "revoke must not drop the connection")
        runner.expectEqual(model.status, "Input stopped on this Mac.", "default revoke message")
    }

    await runner.check("A headset Stop stays stopped until an explicit authorized resume") {
        let configuration = RemoteHostConfiguration(enabled: true, address: "100.64.0.1:58271", allowControl: true, keepAwake: false)
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: configuration, localAddresses: checkLocalAddresses, contentProvider: { throw CheckError.preparationAbandoned })
        model.testMode = true
        model.connected = true
        model.receive(DeskMessage(kind: "heartbeat"))
        model.enableInput()
        runner.expect(model.controlEnabled, "explicit test input consent enables control")
        model.receive(DeskMessage(kind: "stop"))
        runner.expect(!model.controlEnabled, "headset Stop disables control")
        model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(!model.controlEnabled, "ordinary heartbeats must not undo Stop")
        model.receive(DeskMessage(kind: "requestControl"))
        runner.expect(model.controlEnabled, "explicit resume is allowed by remembered owner consent")
        model.revoke()
        model.receive(DeskMessage(kind: "requestControl"))
        model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(!model.controlEnabled, "the headset cannot reverse a Mac owner Stop")
        model.stop()
    }

    await runner.check("A remembered viewing-only headset cannot grant itself control") {
        let configuration = RemoteHostConfiguration(enabled: true, address: "100.64.0.1:58271", allowControl: false, keepAwake: false)
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: configuration, localAddresses: checkLocalAddresses, contentProvider: { throw CheckError.preparationAbandoned })
        model.testMode = true
        model.connected = true
        model.receive(DeskMessage(kind: "heartbeat"))
        model.receive(DeskMessage(kind: "requestControl"))
        runner.expect(!model.controlEnabled, "view-only owner preference is enforced")
        model.stop()
    }

    await runner.check("Continuous input updates diagnostics without redrawing the Mac UI for every event") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        model.testMode = true
        model.connected = true
        model.receive(DeskMessage(kind: "heartbeat"))
        model.enableInput()
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        let displayID = CGMainDisplayID()
        for _ in 0..<100 {
            model.receive(DeskMessage(kind: "input", displayID: displayID, x: 0.5, y: 0.5, action: "move"))
        }
        runner.expectEqual(model.inputCount, 100, "every input is counted immediately")
        runner.expectEqual(publications, 0, "the input burst must not invalidate the entire UI per event")
        try? await Task.sleep(nanoseconds: 350_000_000)
        runner.expect(model.controlEnabled, "the measurement must not pass after watchdog revocation")
        runner.expect(publications >= 1 && publications <= 3, "diagnostics must still refresh on the bounded watchdog cadence")
        model.stop()
    }

    await runner.check("Source losses and peer requests cannot force a keyframe storm") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        guard let id = model.displays.first?.id else { runner.expect(false, "a display is required"); return }
        runner.expect(model.requestKeyframe(displayID: id, at: 100), "the first request is admitted")
        for index in 1..<50 {
            runner.expect(!model.requestKeyframe(displayID: id, at: 100 + Double(index) / 100), "repeated losses share the half-second limiter")
        }
        runner.expect(model.requestKeyframe(displayID: id, at: 100.5), "a recovery request is admitted at expiry")
        runner.expect(!model.requestKeyframe(displayID: UInt32.max, at: 101), "unknown displays cannot consume limiter entries")
        model.stop()
    }

    await runner.check("A one-time Mac control grant cannot override viewing-only reconnect policy") {
        let configuration = RemoteHostConfiguration(enabled: true, address: "100.64.0.1:58271", allowControl: false, keepAwake: false)
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: configuration, localAddresses: checkLocalAddresses, contentProvider: { throw CheckError.preparationAbandoned })
        model.testMode = true
        model.connected = true
        model.receive(DeskMessage(kind: "heartbeat"))
        model.enableInput()
        runner.expect(model.controlEnabled, "the present owner may grant control for this connection")
        model.revoke(ownerPause: false)
        // Construct but never start this channel: attach exercises the real consent path without networking.
        let channel = DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: 1), key: PairingKey.generate())
        model.attach(channel)
        model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(!model.controlEnabled, "a fresh heartbeat after reconnect must respect viewing-only policy")
        model.stop()
    }

    await runner.check("Headset Stop persists through reconnect and explicit Resume restores owner-approved control") {
        let configuration = RemoteHostConfiguration(enabled: true, address: "100.64.0.1:58271", allowControl: true, keepAwake: false)
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: configuration, localAddresses: checkLocalAddresses, contentProvider: { throw CheckError.preparationAbandoned })
        model.testMode = true
        model.connected = true
        model.receive(DeskMessage(kind: "heartbeat"))
        model.enableInput()
        model.receive(DeskMessage(kind: "stop"))
        let channel = DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: 1), key: PairingKey.generate())
        model.attach(channel)
        model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(!model.controlEnabled, "reconnect must not undo the headset Stop")
        model.receive(DeskMessage(kind: "requestControl"))
        runner.expect(model.controlEnabled, "an explicit Resume may use standing owner consent")
        model.stop()
    }

    await runner.check("A sleep or session-resign notification stops sharing and control") {
        let notifications: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        for name in notifications {
            let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
            model.sharing = true
            model.connected = true
            model.controlEnabled = true

            // Posting into this in-process center exercises the observer without asking
            // macOS to sleep, lock, or switch sessions.
            NSWorkspace.shared.notificationCenter.post(name: name, object: nil)
            await drainMainActor()

            runner.expect(!model.sharing, "\(name.rawValue) must stop sharing")
            runner.expect(!model.controlEnabled, "\(name.rawValue) must revoke control")
            runner.expect(!model.connected, "\(name.rawValue) must drop the connection")
        }
    }

    await runner.check("A display arrangement change stops an active session") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        model.sharing = true
        model.connected = true
        model.controlEnabled = true

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drainMainActor()

        runner.expect(!model.sharing, "a display change must stop sharing")
        runner.expect(!model.controlEnabled, "a display change must revoke control")
        runner.expectEqual(
            model.status,
            "Display arrangement changed. Start sharing again to refresh all screens.",
            "display change message"
        )
    }

    await runner.check("Live display inventory is valid, unique and main-display first") {
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        model.refreshInventory()

        runner.expect(!model.displays.isEmpty, "this Mac must report at least one display")
        runner.expect(
            model.displays.allSatisfy(\.isValid),
            "every published display must satisfy DisplayInfo.isValid, or the whole list is dropped on the wire"
        )
        runner.expectEqual(
            Set(model.displays.map(\.id)).count,
            model.displays.count,
            "display identifiers must be unique"
        )
        let main: UInt32? = CGMainDisplayID()
        if model.displays.contains(where: { $0.id == main }) {
            runner.expectEqual(model.displays.first?.id, main, "the main display must sort first")
        }
        for info in model.displays {
            let bounds = CGDisplayBounds(info.id)
            runner.expectClose(info.originX, Double(bounds.minX), "\(info.name) origin x matches CGDisplayBounds")
            runner.expectClose(info.originY, Double(bounds.minY), "\(info.name) origin y matches CGDisplayBounds")
            runner.expectClose(info.pointWidth, Double(bounds.width), "\(info.name) point width matches CGDisplayBounds")
            runner.expectClose(info.pointHeight, Double(bounds.height), "\(info.name) point height matches CGDisplayBounds")
        }
    }
}
