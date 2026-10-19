import AppKit
import Combine
import DeskCore
import DeskTransport
import Foundation
import Network
import ScreenCaptureKit

/// Remote access as the owner uses it: turning it on, the two live preferences, the pairing key,
/// Tailscale's address, what the headset is told, and the display-limit wait. Every model takes
/// its key, preferences, interface addresses and permissions from the check, so nothing reads or
/// writes this Mac's Keychain, user defaults or grants, and no capture or listener starts. A key is
/// only ever compared, never printed, so a failing check cannot put one in the log.
@MainActor
func runRemoteAccessChecks(_ runner: CheckRunner) async {
    let available = HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false)
    let quickReveal = PairingKeyReveal(onRequest: 0.3, firstPairing: 0.6)
    // Constructed but never started: attaching exercises the real session path without a network.
    let unstarted = { DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: 1), key: PairingKey.generate()) }

    func host(_ storage: RemoteStorageRecorder, _ configuration: RemoteHostConfiguration = checkRemoteConfiguration,
              addresses: @escaping () -> [String] = checkLocalAddresses, controlAllowed: Bool = true,
              keepAwake: KeepAwakeHold, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
              inventory: @escaping @MainActor () -> [DisplayInfo] = { [syntheticDisplay(1)] },
              prepare: @escaping () async throws -> SCShareableContent = { throw CheckError.preparationAbandoned }) -> CompanionModel {
        CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: configuration, localAddresses: addresses,
                       loadRemoteKey: storage.load, saveRemoteKey: storage.save, deleteRemoteKey: storage.delete,
                       saveRemoteConfiguration: storage.saveConfiguration, contentProvider: prepare,
                       inventory: inventory, liveSession: { available }, keepAwake: keepAwake, uptime: uptime,
                       screenCaptureAccess: { true }, controlAccess: controlAccess(controlAllowed), keyReveal: quickReveal)
    }

    await runner.check("Turning remote access on needs an address this Mac has, and saves nothing until then") {
        let storage = RemoteStorageRecorder()
        var addresses = ["127.0.0.1"]  // Tailscale is not connected yet
        var prepared = 0
        let model = host(storage, .disabled, addresses: { addresses }, keepAwake: KeepAwakeRecorder().hold,
                         prepare: { prepared += 1; throw CheckError.preparationAbandoned })
        runner.expectEqual(model.configureRemoteAccess(address: "100.64.0.10", allowControl: true, keepAwake: true), .refused,
                           "an address this Mac does not have is refused")
        runner.expectEqual(model.remoteFeedback?.message,
                           "100.64.0.10 isn't on this Mac right now. Make sure Tailscale is connected on this Mac, then try again.",
                           "the owner is told what to check")
        addresses.append("100.64.0.10")
        runner.expectEqual(model.configureRemoteAccess(address: "100.120.30.29", allowControl: true, keepAwake: true), .refused,
                           "another device's address is refused")
        runner.expectEqual(model.remoteFeedback?.fix, .useAddress("100.64.0.10"), "with this Mac's own address on offer")
        runner.expectEqual(model.configureRemoteAccess(address: "192.168.1.20", allowControl: true, keepAwake: true), .refused,
                           "an address outside Tailscale is refused")
        runner.expectEqual(model.remoteFeedback?.fix, .useAddress("100.64.0.10"), "with the same way out")
        runner.expectEqual(model.suggestedRemoteAddress, "100.64.0.10", "which the panel also fills in by itself")
        runner.expect(storage.keySaves == 0 && storage.savedConfigurations.isEmpty, "no key or preference was saved")
        runner.expect(!model.remoteConfiguration.enabled && !model.busy && !model.restartPending && prepared == 0, "and nothing started")
        model.stop()
    }

    await runner.check("Turning remote access on saves one key, shows it for the first pairing only, and starts sharing") {
        let storage = RemoteStorageRecorder()
        let gate = PreparationGate()
        let model = host(storage, .disabled, keepAwake: KeepAwakeRecorder().hold,
                         prepare: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned })
        runner.expectEqual(model.configureRemoteAccess(address: "100.64.0.10", allowControl: false, keepAwake: true), .restarted,
                           "remote access turns on")
        runner.expectEqual(storage.keySaves, 1, "one new key is saved")
        runner.expectEqual(storage.savedConfigurations,
                           [RemoteHostConfiguration(enabled: true, address: "100.64.0.10:58271", allowControl: false, keepAwake: true)],
                           "and the preferences, once")
        runner.expect(model.busy, "sharing starts")
        runner.expect(!model.pairingKey.isEmpty && model.pairingKey == storage.key?.displayValue, "the new key is on screen for the first pairing")
        runner.expect(model.pairingKeyHidesAt != nil, "with the time it hides")
        runner.expectEqual(model.remoteFeedback?.tone, .confirmation, "and the owner is told what to do with it")
        await waitUntil(seconds: 3) { model.pairingKey.isEmpty }
        runner.expect(model.pairingKey.isEmpty && model.pairingKeyHidesAt == nil, "it hides by itself when the reveal ends")
        runner.expect(model.busy, "while sharing carries on")
        model.stop()
        gate.release()
        await drainMainActor()
    }

    await runner.check("Automatic starts and restarts keep the saved key off screen") {
        let storage = RemoteStorageRecorder(key: PairingKey.generate())
        var prepared = 0
        let model = host(storage, keepAwake: KeepAwakeRecorder().hold, prepare: { prepared += 1; throw CheckError.preparationAbandoned })
        var revealed = false
        let observation = model.$pairingKey.sink { if !$0.isEmpty { revealed = true } }
        defer { observation.cancel() }
        model.startConfiguredRemoteAccess()  // as at launch, unlock or wake
        await waitUntil(seconds: 4) { prepared >= 2 }
        runner.expect(prepared >= 2, "the failed start was retried by itself")
        runner.expect(!revealed && model.pairingKey.isEmpty, "the saved key never went on screen")
        model.stop()
    }

    await runner.check("Show Pairing Key reveals the saved key for a while, never with a headset connected, and explains a missing key") {
        let storage = RemoteStorageRecorder(key: PairingKey.generate())
        let model = host(storage, keepAwake: KeepAwakeRecorder().hold)
        model.showRemotePairingKey()
        runner.expect(!model.pairingKey.isEmpty && model.pairingKey == storage.key?.displayValue, "the owner sees the saved key")
        runner.expect(model.pairingKeyHidesAt.map { $0.timeIntervalSinceNow <= quickReveal.onRequest } == true, "for the reveal time only")
        await waitUntil(seconds: 2) { model.pairingKey.isEmpty }
        runner.expect(model.pairingKey.isEmpty && model.pairingKeyHidesAt == nil, "then it hides by itself")
        model.showRemotePairingKey()
        model.attach(unstarted())
        runner.expect(model.pairingKey.isEmpty && model.pairingKeyHidesAt == nil, "a headset connecting hides it at once")
        model.showRemotePairingKey()
        runner.expect(model.pairingKey.isEmpty, "and while one is connected it stays hidden")
        runner.expectEqual(model.remoteFeedback?.tone, .problem, "with the reason beside the button")
        model.stop()
        storage.key = nil
        model.showRemotePairingKey()
        runner.expect(model.pairingKey.isEmpty, "with no saved key there is nothing to show")
        runner.expect(model.remoteFeedback?.message.hasPrefix("No pairing key is saved on this Mac.") == true, "and the owner is told how to make one")
        runner.expectEqual(storage.keySaves, 0, "nothing is made behind the owner's back")
    }

    await runner.check("Turning control off takes it back at once and saves it; only the owner turns it on again") {
        let storage = RemoteStorageRecorder(key: PairingKey.generate())
        let configuration = RemoteHostConfiguration(enabled: true, address: "100.64.0.1:58271", allowControl: true, keepAwake: true)
        let model = host(storage, configuration, keepAwake: KeepAwakeRecorder().hold)
        model.sharing = true
        model.attach(unstarted())
        model.receive(DeskMessage(kind: "heartbeat"))
        model.enableInput()
        runner.expect(model.controlEnabled, "the remembered headset has control")
        model.setRemoteControlAllowed(false)
        runner.expect(!model.controlEnabled, "turning control off takes it back at once")
        runner.expect(!model.remoteConfiguration.allowControl && storage.savedConfigurations.last?.allowControl == false, "and saves it")
        runner.expectEqual(model.lastHeadsetNotice, HeadsetNotice.controlTurnedOff, "the headset is told")
        model.receive(DeskMessage(kind: "requestControl"))
        model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(!model.controlEnabled, "neither a request nor a heartbeat turns it back on")
        runner.expectEqual(model.lastHeadsetNotice, HeadsetNotice.controlRefused(remote: true, allowed: false), "and the request is answered")
        model.attach(unstarted())
        model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(!model.controlEnabled, "a reconnect stays view-only")
        runner.expect(model.sharing && model.connected && !model.busy && !model.restartPending, "sharing was never restarted")
        model.setRemoteControlAllowed(true)
        runner.expect(model.remoteConfiguration.allowControl && storage.savedConfigurations.last?.allowControl == true, "turning it on again is saved")
        model.receive(DeskMessage(kind: "heartbeat"))
        runner.expect(model.controlEnabled, "and the connected headset gets control at its next heartbeat")
        model.stop()
    }

    await runner.check("Saving the same address changes nothing, and keep-awake applies without a restart") {
        let storage = RemoteStorageRecorder(key: PairingKey.generate())
        let recorder = KeepAwakeRecorder()
        let configuration = RemoteHostConfiguration(enabled: true, address: "100.64.0.1:58271", allowControl: false, keepAwake: false)
        let model = host(storage, configuration, keepAwake: recorder.hold)
        model.sharing = true
        model.attach(unstarted())
        runner.expectEqual(model.configureRemoteAccess(address: "100.64.0.1", allowControl: false, keepAwake: false), .unchanged,
                           "Return on the saved address")
        runner.expect(storage.keySaves == 0 && storage.savedConfigurations.isEmpty, "saves nothing")
        model.setRemoteKeepAwake(true)
        runner.expect(recorder.hold.isHeld && storage.savedConfigurations.last?.keepAwake == true, "keep-awake takes hold at once and is saved")
        model.setRemoteKeepAwake(false)
        runner.expect(!recorder.hold.isHeld && storage.savedConfigurations.last?.keepAwake == false, "and lets go at once")
        runner.expect(model.sharing && model.connected && !model.busy && !model.restartPending, "the headset stayed connected throughout")
        model.stop()
    }

    await runner.check("An unattended start waits for Tailscale without reading the key or preparing capture") {
        var addresses = ["127.0.0.1"]
        var loads = 0, prepared = 0
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: { addresses },
                                   loadRemoteKey: { loads += 1; return PairingKey.generate() },
                                   contentProvider: { prepared += 1; throw CheckError.preparationAbandoned },
                                   inventory: { [syntheticDisplay(1)] }, liveSession: { available }, keepAwake: KeepAwakeRecorder().hold)
        model.start()
        runner.expect(model.restartPending && !model.busy, "the host waits and will try again")
        runner.expect(loads == 0 && prepared == 0, "without reading the key or preparing capture")
        runner.expectEqual(model.status, "Waiting for Tailscale to connect this Mac at 100.64.0.1. Retrying in 2 s.",
                           "the status says what it waits for")
        addresses.append("100.64.0.1")  // Tailscale connects
        await waitUntil(seconds: 4) { prepared >= 1 }
        runner.expect(loads == 1 && prepared >= 1, "the next retry goes ahead once Tailscale has connected")
        model.stop()
    }

    await runner.check("A control request the Mac cannot grant tells the headset what is missing") {
        let storage = RemoteStorageRecorder(key: PairingKey.generate())
        let configuration = RemoteHostConfiguration(enabled: true, address: "100.64.0.1:58271", allowControl: true, keepAwake: false)
        let asked = host(storage, configuration, controlAllowed: false, keepAwake: KeepAwakeRecorder().hold)
        asked.sharing = true
        asked.attach(unstarted())
        asked.receive(DeskMessage(kind: "heartbeat"))
        asked.receive(DeskMessage(kind: "requestControl"))  // Resume Control
        runner.expect(!asked.controlEnabled, "without Accessibility, control stays off")
        runner.expectEqual(asked.lastHeadsetNotice, HeadsetNotice.controlNeedsAccessibility, "and the headset is told why")
        runner.expectEqual(asked.status, HeadsetNotice.controlNeedsAccessibility, "as is the Mac")
        asked.stop()
        let gate = PreparationGate()
        let reconnecting = host(storage, configuration, controlAllowed: false, keepAwake: KeepAwakeRecorder().hold,
                                prepare: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned })
        reconnecting.startConfiguredRemoteAccess()  // control allowed for the remembered headset
        reconnecting.attach(unstarted())
        reconnecting.receive(DeskMessage(kind: "heartbeat"))  // its automatic grant
        runner.expect(!reconnecting.controlEnabled, "a reconnect's automatic grant is refused the same way")
        runner.expectEqual(reconnecting.lastHeadsetNotice, HeadsetNotice.controlNeedsAccessibility, "and says so too")
        reconnecting.stop()
        gate.release()
        await drainMainActor()
        let viewOnly = host(storage, controlAllowed: false, keepAwake: KeepAwakeRecorder().hold)
        viewOnly.setRemoteControlAllowed(true)
        runner.expect(!viewOnly.remoteConfiguration.allowControl, "control cannot be allowed without Accessibility")
        runner.expectEqual(viewOnly.remoteFeedback?.fix, .allowAccessibility, "and the panel offers the permission")
        viewOnly.stop()
    }

    await runner.check("The headset is told why sharing ended or paused") {
        let storage = RemoteStorageRecorder(key: PairingKey.generate())
        let paused = host(storage, keepAwake: KeepAwakeRecorder().hold)
        paused.sharing = true
        paused.attach(unstarted())
        paused.receiveSessionNotice(.locked)
        runner.expectEqual(paused.lastHeadsetNotice, "The Mac locked. Sharing resumes when it is unlocked.", "a lock pauses a remote host")
        paused.stop()
        let rearranged = host(storage, keepAwake: KeepAwakeRecorder().hold, inventory: { [syntheticDisplay(1), syntheticDisplay(2)] })
        rearranged.sharing = true
        rearranged.attach(unstarted())
        rearranged.displayConfigurationChanged()
        runner.expectEqual(rearranged.lastHeadsetNotice, HeadsetNotice.displaysChanged(resumes: true), "a display change restarts it")
        runner.expect(rearranged.restartPending, "as it says")
        rearranged.stop()
        let turnedOff = host(storage, keepAwake: KeepAwakeRecorder().hold)
        turnedOff.sharing = true
        turnedOff.attach(unstarted())
        turnedOff.disableRemoteAccess()
        runner.expectEqual(turnedOff.lastHeadsetNotice, HeadsetNotice.remoteTurnedOff, "turning remote access off")
        let local = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned }, inventory: { [syntheticDisplay(1)] },
                                   liveSession: { available })
        local.sharing = true
        local.attach(unstarted())
        local.receiveSessionNotice(.locked)
        runner.expectEqual(local.lastHeadsetNotice, "The Mac locked, so sharing stopped.", "a one-session host does not promise to resume")
        local.attach(unstarted())
        local.stop()
        runner.expectEqual(local.lastHeadsetNotice, HeadsetNotice.stopped, "and Stop Sharing says just that")
    }

    await runner.check("Disable & Forget turns remote access off, forgets the key and leaves nothing on screen") {
        let storage = RemoteStorageRecorder(key: PairingKey.generate())
        let model = host(storage, keepAwake: KeepAwakeRecorder().hold)
        model.showRemotePairingKey()
        model.disableRemoteAccess()
        runner.expect(storage.key == nil && storage.keyDeletes == 1, "the key is forgotten")
        runner.expectEqual(storage.savedConfigurations.last, .disabled, "remote access is saved off")
        runner.expect(!model.remoteConfiguration.enabled && model.pairingKey.isEmpty && model.pairingKeyHidesAt == nil,
                      "and no key stays on screen")
        runner.expectEqual(model.remoteFeedback?.tone, .confirmation, "the owner is told it is done")
        model.stop()
    }

    await runner.check("Removing an unselected fifth display leaves remote preparation intact") {
        let clock = ManualClock()
        var inventory = (1...5).map { syntheticDisplay(UInt32($0)) }
        let model = host(RemoteStorageRecorder(key: PairingKey.generate()), keepAwake: KeepAwakeRecorder().hold,
                         uptime: { clock.now }, inventory: { inventory })
        model.start()
        runner.expect(model.busy && !model.restartPending, "five available screens prepare the selected four immediately")
        runner.expectEqual(model.displays.map(\.id), [1, 2, 3, 4], "the fifth screen stays outside the selected session")
        let sessionInventory = model.sessionInventory
        inventory.removeLast()
        model.displayConfigurationChanged()
        runner.expect(model.busy && !model.restartPending, "removing an unselected source does not restart preparation")
        runner.expectEqual(model.sessionInventory, sessionInventory, "the selected session remains identical")
        runner.expectEqual(model.availableDisplays.map(\.id), [1, 2, 3, 4], "the available-source list still refreshes")
        model.stop()
    }

    await runner.check("The setup panel is told that a remote host remembers its headset") {
        let model = host(RemoteStorageRecorder(key: PairingKey.generate()), keepAwake: KeepAwakeRecorder().hold)
        model.listenerKeepsPairing = true
        model.sharing = true  // with no headset connected and no key on screen: the normal unattended state
        @MainActor func readiness(remembered: Bool) -> SetupReadiness {
            SetupReadiness(snapshot: SetupSnapshot(displayCount: model.displays.count, screenRecordingAllowed: model.screenPermission,
                                                   accessibilityAllowed: model.inputPermission, preparing: false, sharing: true,
                                                   connected: false, controlEnabled: false, testMode: model.testMode,
                                                   pairingKeyReady: false, rememberedPairing: remembered))
        }
        runner.expect(model.setupReadiness == readiness(remembered: true), "it is evaluated as waiting for the remembered headset")
        runner.expect(model.setupReadiness != readiness(remembered: false), "not as a one-session host that needs a fresh key")
        model.stop()
    }

    await runner.check("This Mac's interface list is read without the network, and Tailscale's range is picked out") {
        let addresses = LocalNetworkAddresses.ipv4()
        runner.expect(addresses.contains("127.0.0.1"), "loopback is always listed")
        runner.expect(addresses.allSatisfy { RemoteMacAddress(host: $0)?.host == $0 && !$0.contains(":") }, "each as a plain IPv4 address")
        runner.expectEqual(LocalNetworkAddresses.tailnet(["127.0.0.1", "100.64.0.10", "100.64.0.1", "100.128.0.1", "10.0.0.2", "100.64.0.10"]),
                           ["100.64.0.10", "100.64.0.1"], "only Tailscale's range, once each")
        print("      this Mac lists \(LocalNetworkAddresses.tailnet(addresses).count) Tailscale address(es) right now")
    }
}
