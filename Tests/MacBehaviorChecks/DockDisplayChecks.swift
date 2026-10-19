import DeskCore
import DeskTransport
import Foundation

@MainActor
func runDockDisplayChecks(_ runner: CheckRunner) async {
    let available = HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false)
    await runner.check("Dock removal and return rebuild nearby sharing without restoring stopped input") {
        var inventory = (1...4).map { syntheticDisplay(UInt32($0)) }
        let key = PairingKey.generate()
        let model = CompanionModel(lanConfiguration: LANHostConfiguration(enabled: true),
                                   loadLANKey: { key }, saveLANKey: { _ in }, saveLANConfiguration: { _ in },
                                   contentProvider: { throw CheckError.preparationAbandoned },
                                   inventory: { inventory }, liveSession: { available },
                                   keepAwake: KeepAwakeRecorder().hold, screenCaptureAccess: { true },
                                   controlAccess: controlAccess(false))
        model.ownerPausedControl = true
        model.peerPausedControl = true
        model.sharing = true
        model.sessionInventory = inventory
        model.displayConfigurationChanged()
        runner.expect(model.sharing && !model.restartPending, "unchanged display notifications do not interrupt sharing")
        inventory = [syntheticDisplay(1)]
        model.displayConfigurationChanged()
        runner.expect(!model.sharing && model.restartPending, "unplugging the dock schedules the built-in-only capture")
        runner.expect(model.ownerPausedControl && model.peerPausedControl && !model.controlEnabled, "both Stop decisions survive rebuilding")
        runner.expect(model.lanConfiguration.enabled, "nearby availability remains saved")
        model.resumeTask?.cancel(); model.resumeTask = nil
        model.sharing = true
        model.sessionInventory = inventory
        inventory = (1...4).map { syntheticDisplay(UInt32($0)) }
        model.displayConfigurationChanged()
        runner.expect(model.restartPending && !model.controlEnabled, "returning three dock screens schedules all four without granting input")
        model.stop()
        model.displayConfigurationChanged()
        runner.expect(!model.restartPending && !model.lanConfiguration.enabled, "manual Stop prevents dock notifications from restarting sharing")
    }

    await runner.check("Incomplete ScreenCaptureKit inventory remains retryable without hiding dock sources") {
        let inventory = (1...4).map { syntheticDisplay(UInt32($0)) }
        do {
            try DisplayCapturePlan.validate(inventory: inventory, capturableIDs: [1])
            runner.expect(false, "three missing dock sources must not silently disappear")
        } catch {
            runner.expectEqual(CaptureFailure(error).disposition, .retry, "capture can recover when dock enumeration catches up")
        }
    }

    await runner.check("Source selection is bounded, saved only on owner action, and frozen while sharing") {
        var saved: [Set<UInt32>?] = []
        let model = CompanionModel(saveDisplaySelection: { saved.append($0) },
                                   inventory: { (1...5).map { syntheticDisplay(UInt32($0)) } },
                                   liveSession: { available }, keepAwake: KeepAwakeRecorder().hold,
                                   screenCaptureAccess: { true }, controlAccess: controlAccess(false))
        runner.expectEqual(model.availableDisplays.count, 5, "all connected screens remain visible")
        runner.expectEqual(model.displays.map(\.id), [1, 2, 3, 4], "automatic selection shares only four")
        runner.expect(saved.isEmpty, "inventory observation never changes saved selection")
        model.setDisplayShared(4, shared: false)
        model.setDisplayShared(5, shared: true)
        runner.expectEqual(model.displays.map(\.id), [1, 2, 3, 5], "owner may replace a selected source")
        runner.expectEqual(saved.count, 2, "each explicit change is persisted through injected storage")
        model.setDisplayShared(4, shared: true)
        runner.expectEqual(saved.count, 2, "a fifth selected source is refused")
        model.sharing = true
        model.setDisplayShared(5, shared: false)
        runner.expectEqual(model.displays.map(\.id), [1, 2, 3, 5], "a running selection cannot change underneath input")
        model.sharing = false
        model.useAutomaticDisplaySelection()
        runner.expectEqual(model.displays.map(\.id), [1, 2, 3, 4], "automatic selection can be restored")
        runner.expect(model.selectedDisplayIDs == nil && saved.count == 3, "reset saves the automatic preference")
        model.stop()
    }

    await runner.check("An unavailable saved source waits safely and resumes when its physical identity returns") {
        var inventory = [syntheticDisplay(9)]
        var identities: [UInt32: String] = [9: "different-screen"]
        var preparations = 0
        let model = CompanionModel(resolveDisplaySelection: { _ in
            DisplayCapturePlan.resolve(identities: ["chosen-screen"], current: identities)
        }, lanConfiguration: LANHostConfiguration(enabled: true),
           loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in },
           contentProvider: { preparations += 1; throw CheckError.preparationAbandoned },
           inventory: { inventory }, liveSession: { available }, keepAwake: KeepAwakeRecorder().hold,
           screenCaptureAccess: { true }, controlAccess: controlAccess(false))
        model.start()
        runner.expect(!model.busy && !model.sharing && !model.restartPending, "missing choice starts no capture or retry loop")
        runner.expect(model.status.contains("selected screens are unavailable"), "the owner gets a specific selection recovery step")
        runner.expectEqual(preparations, 0, "another connected screen is never captured instead")
        inventory = [syntheticDisplay(42)]
        identities = [42: "chosen-screen"]
        model.displayConfigurationChanged()
        runner.expectEqual(model.displays.map(\.id), [42], "the UUID resolves to a new runtime ID")
        runner.expect(model.restartPending && !model.controlEnabled, "returning chosen screen resumes without granting input")
        model.stop()
    }
}
