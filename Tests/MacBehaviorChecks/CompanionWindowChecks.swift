import AppKit
import DeskCore
import DeskTransport
import Foundation

/// The companion window's lifecycle through `CompanionWindowLifecycle`, the object the window, the
/// menu bar item and the app delegate's reopen callback call into, with a real `CompanionModel`.
/// SwiftUI's scene and AppKit's event routing are not part of the harness: the open action and
/// app activation are counted here rather than performed, so no window is ever shown.
@MainActor
func runCompanionWindowChecks(_ runner: CheckRunner) async {
    let key = PairingKey.generate()
    let available = HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false)

    await runner.check("Reopening the companion window asks for its one scene and leaves sharing alone") {
        var opens = 0, activations = 0, loads = 0
        let gate = PreparationGate()
        let lifecycle = CompanionWindowLifecycle(activate: { activations += 1 })
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { loads += 1; return key },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { [syntheticDisplay(1)] }, liveSession: { available },
                                   keepAwake: KeepAwakeRecorder().hold)
        runner.expect(lifecycle.shouldHandleReopen(), "before any window has appeared, AppKit's own reopen runs")
        runner.expectEqual(activations, 0, "and nothing is activated")

        lifecycle.register { opens += 1 }
        runner.expect(lifecycle.windowAppeared(model, arguments: []), "the window's first appearance is the launch")
        runner.expect(model.busy && loads == 1, "which starts the configured remote host")

        lifecycle.windowClosed(model)
        runner.expect(model.busy && !model.restartPending, "closing the window leaves the remote host running")
        runner.expect(!lifecycle.shouldHandleReopen(), "a Dock click or second launch is handled, so AppKit adds no window")
        runner.expect(opens == 1 && activations == 1, "it opens the companion scene with the app active")
        runner.expect(!lifecycle.windowAppeared(model, arguments: []), "the recreated window is not a launch")
        runner.expect(model.busy && loads == 1, "so hosting is neither restarted nor changed")

        model.stop()  // the owner stops sharing, closes the window and opens it from the menu bar
        lifecycle.windowClosed(model)
        runner.expect(lifecycle.show(), "the menu bar item shows the companion")
        runner.expect(opens == 2 && activations == 2, "through the same scene, with the app active")
        runner.expect(!lifecycle.windowAppeared(model, arguments: []), "the reopened window starts nothing")
        runner.expect(!model.busy && !model.sharing && !model.restartPending && !model.autoRecoveryArmed && loads == 1,
                      "sharing the owner stopped stays stopped")
        gate.release()
        await drainMainActor()
    }

    await runner.check("A remembered nearby host stays available with its window closed") {
        let gate = PreparationGate()
        let lifecycle = CompanionWindowLifecycle(activate: {})
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { [syntheticDisplay(1)] }, liveSession: { available },
                                   keepAwake: KeepAwakeRecorder().hold)
        model.start()
        runner.expect(model.busy, "a local session is being prepared")
        lifecycle.windowClosed(model)
        runner.expect(model.busy && model.lanConfiguration.enabled, "closing the window leaves the nearby host available")
        model.stop()
        gate.release()
        await drainMainActor()
    }
}
