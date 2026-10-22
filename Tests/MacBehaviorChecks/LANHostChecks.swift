import Foundation
import Security
import Network
import DeskCore
import DeskTransport

@MainActor
func runLANHostChecks(_ runner: CheckRunner) async {
    let available = HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false)
    let connection = { DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: 1), key: PairingKey.generate()) }
    func host(_ storage: RemoteStorageRecorder, configuration: LANHostConfiguration = .disabled,
              save: @escaping (LANHostConfiguration) -> Void = { _ in }) -> CompanionModel {
        CompanionModel(lanConfiguration: configuration, loadLANKey: storage.load, saveLANKey: storage.save, deleteLANKey: storage.delete,
                       saveLANConfiguration: save, saveRemoteConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned },
                       inventory: { [syntheticDisplay(1)] }, liveSession: { available },
                       keepAwake: KeepAwakeRecorder().hold, screenCaptureAccess: { true },
                       controlAccess: controlAccess(true), keyReveal: PairingKeyReveal(onRequest: 0.05, firstPairing: 0.05))
    }

    await runner.check("LAN listener uses one retained credential and a stable advertised route across hosts") {
        let storage = RemoteStorageRecorder()
        let first = host(storage)
        let plan = try first.listenerPlan(remote: nil)
        runner.expect(plan.bindHost == nil && plan.port == nil && plan.allowsReconnect, "nearby is advertised and remains listening")
        runner.expectEqual(storage.keySaves, 1, "first pairing stores one credential")
        let again = try first.listenerPlan(remote: nil)
        let second = host(storage)
        let afterRelaunch = try second.listenerPlan(remote: nil, allowCreation: false)
        runner.expect(plan.key.displayValue == again.key.displayValue && plan.key.displayValue == afterRelaunch.key.displayValue, "starts and relaunches accept the original credential")
        runner.expectEqual(plan.name, afterRelaunch.name, "the service name stays stable")
        runner.expectEqual(storage.keySaves, 1, "no automatic rotation")
        first.stop(); second.stop()
    }

    await runner.check("Automatic LAN starts do not recreate a missing credential or reveal a retained one") {
        let storage = RemoteStorageRecorder()
        let model = host(storage, configuration: LANHostConfiguration(enabled: true))
        do { _ = try model.listenerPlan(remote: nil, allowCreation: false); runner.expect(false, "missing credential must fail") }
        catch { runner.expectEqual(storage.keySaves, 0, "an automatic start never replaces pairing") }
        storage.key = PairingKey.generate()
        _ = try model.listenerPlan(remote: nil, allowCreation: false)
        runner.expect(model.pairingKey.isEmpty, "saved pairing stays off screen")
        model.showPairingKey()
        runner.expect(!model.pairingKey.isEmpty, "the owner can reveal it")
        await waitUntil(seconds: 1) { model.pairingKey.isEmpty }
        runner.expect(model.pairingKey.isEmpty, "the reveal hides itself")
        model.attach(connection()); model.showPairingKey()
        runner.expect(model.pairingKey.isEmpty, "an attached headset never sees the key")
        model.stop()
    }

    await runner.check("Persistence is promised only by an active remembered listener") {
        let model = host(RemoteStorageRecorder(key: PairingKey.generate()))
        runner.expect(model.headsetStatus("Ready").keepsPairing == nil, "an unstarted host makes no persistence promise")
        model.listenerKeepsPairing = true // The actual successful server-start branch sets this.
        runner.expect(model.headsetStatus("Connected").keepsPairing == true, "authenticated attach and later statuses carry the promise")
        model.stop()
        runner.expect(model.headsetStatus("Stopped").keepsPairing == nil, "teardown withdraws the listener promise")
    }

    await runner.check("LAN disconnect keeps availability while releasing input and allowing the next connection") {
        let storage = RemoteStorageRecorder(key: PairingKey.generate())
        let model = host(storage, configuration: LANHostConfiguration(enabled: true))
        let first = connection()
        model.sharing = true; model.listenerKeepsPairing = true
        model.attach(first)
        model.receive(DeskMessage(kind: "heartbeat")); model.enableInput()
        runner.expect(model.controlEnabled, "the owner can grant this session")
        first.onState?(.disconnected("Link lost"))
        runner.expect(model.sharing && model.lanConfiguration.enabled && !model.connected && !model.controlEnabled, "listener availability stays on and input is released")
        model.attach(connection()); model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(!model.controlEnabled, "a one-connection grant is not unattended consent")
        model.stop()
        runner.expect(!model.lanConfiguration.enabled, "Stop Sharing withdraws saved availability")
    }

    await runner.check("LAN standing consent and both Stop decisions survive reconnects and application restart") {
        let storage = RemoteStorageRecorder(key: PairingKey.generate())
        var saved = LANHostConfiguration.disabled
        let model = host(storage, configuration: LANHostConfiguration(enabled: true), save: { saved = $0 })
        model.setLANControlAllowed(true)
        model.attach(connection()); model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(model.controlEnabled, "explicit standing consent permits a grant after heartbeat")
        model.receive(DeskMessage(kind: "stop"))
        runner.expect(saved.peerPaused, "the headset Stop is saved")
        model.attach(connection()); model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(!model.controlEnabled, "the headset Stop holds at reconnect")
        let reopened = host(storage, configuration: saved)
        reopened.attach(connection()); reopened.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(!reopened.controlEnabled, "the headset Stop holds after restart")
        reopened.enableInput(); reopened.revoke()
        let ownerStopped = host(storage, configuration: reopened.lanConfiguration)
        ownerStopped.attach(connection()); ownerStopped.receive(DeskMessage(kind: "heartbeat")); ownerStopped.receive(DeskMessage(kind: "requestControl"))
        runner.expect(!ownerStopped.controlEnabled && ownerStopped.lanConfiguration.ownerPaused, "the Mac Stop holds through relaunch and requests")
        model.stop(); reopened.stop(); ownerStopped.stop()
    }

    await runner.check("LAN preferences survive isolated storage and contain no pairing credential") {
        let name = "VisionDesk.checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let policy = LANHostConfiguration(enabled: true, allowControl: true, ownerPaused: true, peerPaused: true)
        policy.save(defaults: defaults)
        runner.expectEqual(LANHostConfiguration.load(defaults: defaults), policy, "owner choices persist across a load")
        let keys = Set(defaults.persistentDomain(forName: name)?.keys ?? Dictionary<String, Any>().keys)
        runner.expectEqual(keys.count, 1, "only the non-secret policy record is written")
    }

    await runner.check("Reset Pairing stops sharing and changes only the LAN credential") {
        let original = PairingKey.generate()
        let storage = RemoteStorageRecorder(key: original)
        let model = host(storage, configuration: LANHostConfiguration(enabled: true, allowControl: true))
        model.sharing = true; model.attach(connection())
        model.resetLANPairing()
        runner.expect(!model.sharing && !model.connected && !model.lanConfiguration.enabled && !model.lanConfiguration.allowControl, "reset stops the host and removes standing consent")
        runner.expect(storage.key?.displayValue != original.displayValue && storage.keySaves == 1, "the explicit reset replaces the LAN key")
        runner.expect(!model.pairingKey.isEmpty, "the new key is available for pairing")
        model.hidePairingKey(); model.stop()
    }

    await runner.check("Rejected nearby pairing stops without retry or credential replacement") {
        var loads = 0
        var mutations = 0
        let model = CompanionModel(loadLANKey: { loads += 1; throw PairingKeyStoreError.untrustedItemPolicy },
                                   saveLANKey: { _ in mutations += 1 }, deleteLANKey: { mutations += 1 },
                                   saveLANConfiguration: { _ in },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { runner.expect(false, "rejected credentials must not capture"); throw CheckError.preparationAbandoned },
                                   inventory: { [syntheticDisplay(1)] }, liveSession: { available })
        model.start()
        runner.expect(loads == 1 && mutations == 0, "start does not mutate rejected credentials")
        runner.expect(!model.restartPending && !model.busy && !model.sharing, "policy rejection is terminal")
        runner.expect(model.status.contains("reset pairing"), "the actionable repair is shown")
        model.stop()
    }

    await runner.check("Confirmed reset deletes before saving and reports replacement failure honestly") {
        var operations: [String] = []
        let model = CompanionModel(loadLANKey: { throw PairingKeyStoreError.untrustedItemPolicy },
                                   saveLANKey: { _ in operations.append("save"); throw PairingKeyStoreError.accessDenied(errSecAuthFailed) },
                                   deleteLANKey: { operations.append("delete") }, saveLANConfiguration: { _ in },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { throw CheckError.preparationAbandoned })
        model.resetLANPairing()
        runner.expectEqual(operations, ["delete", "save"], "only confirmed reset bypasses the unusable old item by deleting first")
        runner.expect(!model.sharing && !model.restartPending && model.pairingKey.isEmpty, "no unsafe sharing or reveal after replacement fails")
        runner.expect(model.status.contains("Old pairing removed"), "the old credential is not claimed to survive deletion")
        model.stop()
    }

    await runner.check("Denied reset deletion preserves the existing item and never attempts a save") {
        var saves = 0
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in saves += 1 },
                                   deleteLANKey: { throw PairingKeyStoreError.accessDenied(errSecAuthFailed) },
                                   saveLANConfiguration: { _ in }, saveRemoteConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned })
        model.resetLANPairing()
        runner.expect(saves == 0 && model.pairingKey.isEmpty && !model.sharing, "delete refusal cannot rotate or reveal a replacement")
        runner.expect(model.status.contains("old item was kept"), "failure reports preservation")
        model.stop()
    }

    await runner.check("A same-network switch selects one LAN listener and preserves remote pairing and policy") {
        let lan = RemoteStorageRecorder(key: PairingKey.generate())
        let remote = RemoteStorageRecorder(key: PairingKey.generate())
        let original = remote.key?.displayValue
        let configuration = RemoteHostConfiguration(enabled: true, address: "100.64.0.1:58271", allowControl: true, keepAwake: true)
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: lan.load, saveLANKey: lan.save, saveLANConfiguration: { _ in },
                                   remoteConfiguration: configuration, localAddresses: checkLocalAddresses,
                                   loadRemoteKey: remote.load, saveRemoteKey: remote.save, deleteRemoteKey: remote.delete,
                                   saveRemoteConfiguration: remote.saveConfiguration,
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { [syntheticDisplay(1)] }, liveSession: { available }, keepAwake: KeepAwakeRecorder().hold,
                                   screenCaptureAccess: { true }, controlAccess: controlAccess(true))
        model.sharing = true; model.attach(connection()); model.receive(DeskMessage(kind: "heartbeat")); model.enableInput()
        model.useNearbyConnection()
        runner.expect(!model.remoteConfiguration.enabled && model.busy && !model.connected && !model.controlEnabled,
                      "the remote connection ends and only nearby preparation starts")
        runner.expect(model.remoteConfiguration.address == configuration.address && model.remoteConfiguration.allowControl == configuration.allowControl,
                      "remote route and consent remain saved")
        runner.expect(remote.key?.displayValue == original && remote.keyDeletes == 0 && remote.keySaves == 0, "remote credentials are untouched")
        model.stop(); gate.release(); await drainMainActor()
        _ = model.configureRemoteAccess(address: configuration.address, allowControl: true, keepAwake: true)
        runner.expect(model.remoteConfiguration.enabled && remote.key?.displayValue == original && remote.keySaves == 0,
                      "switching back explicitly reuses the old remote key")
        model.stop(); await drainMainActor()
    }

    await runner.check("Saved nearby availability restarts quietly and a manual Stop persists through relaunch") {
        let storage = RemoteStorageRecorder(key: PairingKey.generate())
        let model = host(storage, configuration: LANHostConfiguration(enabled: true))
        model.startSavedHosting()
        runner.expect(model.busy && model.pairingKey.isEmpty, "saved hosting prepares without revealing the retained key")
        model.stop(manual: false)
        runner.expect(model.lanConfiguration.enabled, "application quit and recovery keep saved availability")
        model.stop()
        let reopened = host(storage, configuration: model.lanConfiguration)
        reopened.startSavedHosting()
        runner.expect(!reopened.busy && !reopened.restartPending, "an owner Stop stays stopped on relaunch")
        reopened.stop(); await drainMainActor()
    }

    await runner.check("A remote listener stays bound and uses the separate remote credential") {
        let lan = RemoteStorageRecorder(key: PairingKey.generate())
        let remoteKey = PairingKey.generate()
        let model = host(lan)
        let endpoint = RemoteMacAddress(string: "100.64.0.1:58271")!
        let plan = try model.listenerPlan(remote: (endpoint, remoteKey))
        runner.expectEqual(plan.bindHost, endpoint.host, "remote is bound and never advertised")
        runner.expect(plan.key.displayValue == remoteKey.displayValue && plan.key.displayValue != lan.key?.displayValue, "the remote key is preserved and independent")
        runner.expectEqual(lan.keySaves, 0, "no LAN key is rewritten")
        model.stop()
    }
}
