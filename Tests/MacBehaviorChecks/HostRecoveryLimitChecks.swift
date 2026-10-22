import AppKit
import Combine
import DeskCore
import DeskTransport
import Foundation
import ScreenCaptureKit

/// How far unattended recovery goes without anyone at the Mac: how long it keeps the Mac awake
/// while restarts keep failing, and how display selection keeps an extra source from blocking sharing. Every
/// model injects its pairing-key loader, live session, inventory, keep-awake hold and, where time
/// matters, its clock, so nothing reads the Keychain, creates a power assertion or waits minutes.
@MainActor
func runHostRecoveryLimitChecks(_ runner: CheckRunner) async {
    let key = PairingKey.generate()
    let available = HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false)
    let limit = RemoteRecoveryBackoff.keepAwakeLimitSeconds

    await runner.check("Recovery keeps the Mac awake for a bounded window from the first failure") {
        var backoff = RemoteRecoveryBackoff()
        runner.expect(backoff.keepsAwake(at: 0), "a host that has not failed may keep the Mac awake")
        backoff.recordFailure(at: 1_000)
        runner.expect(backoff.keepsAwake(at: 1_000 + limit - 1), "inside the window")
        backoff.recordFailure(at: 1_000 + limit - 1)
        runner.expect(!backoff.keepsAwake(at: 1_000 + limit), "measured from the first failure of the run, not the latest")
        backoff.reset()
        runner.expect(backoff.keepsAwake(at: 1_000 + 2 * limit), "a stable session or a deliberate pause starts a fresh window")
        // How many restarts the window spans on the production schedule.
        var schedule = RemoteRecoveryBackoff()
        var elapsed = 0.0
        var attempts = 0
        while true {
            schedule.recordFailure(at: 0)
            elapsed += Double(schedule.delaySeconds)
            guard elapsed < limit else { break }
            attempts += 1
        }
        runner.expect(attempts >= 20, "the window outlasts the backoff ramp by many ceiling attempts, got \(attempts)")
        print("      recovery keep-awake window: \(Int(limit / 60)) min, \(attempts) restart attempts on the backoff schedule")
        runner.expectEqual(RemoteRecoveryBackoff.status("Capture stopped: gone.", retryingIn: 30, keepingAwake: false),
                           "Capture stopped: gone. Retrying in 30 s. This Mac is no longer kept awake while it retries.",
                           "past the window the status says the Mac may sleep")
    }

    await runner.check("Restarts that keep failing stop holding the Mac awake after the window but keep trying") {
        let clock = ManualClock()
        let recorder = KeepAwakeRecorder()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { throw CheckError.preparationAbandoned },
                                   inventory: { [syntheticDisplay(1)] }, liveSession: { available },
                                   keepAwake: recorder.hold, uptime: { clock.now })
        recorder.hold.hold()
        model.sharing = true
        let interrupted = CaptureFailure(NSError(domain: SCStreamErrorDomain, code: -3821))
        model.captureEnded(interrupted)
        runner.expect(recorder.hold.isHeld && model.restartPending, "the first restart keeps the Mac awake")
        clock.advance(by: limit - 1)
        model.captureEnded(interrupted)
        runner.expect(recorder.hold.isHeld && model.restartPending, "still inside the window")
        runner.expect(model.status.hasSuffix("Retrying in 4 s."), "an ordinary retry status, got: \(model.status)")
        clock.advance(by: 1)
        model.captureEnded(interrupted)
        runner.expect(!recorder.hold.isHeld && recorder.ends == 1, "past the window the hold is released once")
        runner.expect(model.restartPending, "and recovery keeps going without it")
        runner.expect(model.status.hasSuffix("This Mac is no longer kept awake while it retries."), "the status says so, got: \(model.status)")
        model.stop()
        runner.expect(!model.restartPending, "the owner's stop still ends recovery")
        runner.expectEqual(recorder.ends, 1, "and does not release the hold a second time")
    }

    await runner.check("A pairing key that stays unreadable keeps retrying without holding the Mac awake forever") {
        let clock = ManualClock()
        let recorder = KeepAwakeRecorder()
        var loads = 0
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses,
                                   loadRemoteKey: { loads += 1; throw CheckError.preparationAbandoned },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { throw CheckError.preparationAbandoned },
                                   inventory: { [syntheticDisplay(1)] }, liveSession: { available },
                                   keepAwake: recorder.hold, uptime: { clock.now })
        recorder.hold.hold()  // as after a session that was shared with keep-awake on
        model.start()
        runner.expect(loads == 1 && model.restartPending && recorder.hold.isHeld, "an unreadable key retries and keeps the Mac awake at first")
        runner.expect(model.status.contains("Keychain may still be locked"), "the status explains why, got: \(model.status)")
        clock.advance(by: limit)
        await waitUntil(seconds: 4) { loads >= 2 }
        runner.expect(loads >= 2, "the scheduled retry reads the key again on its own")
        runner.expect(!recorder.hold.isHeld, "past the window that retry no longer holds the Mac awake")
        runner.expect(model.restartPending, "and another attempt is scheduled")
        model.stop()
        runner.expect(!model.restartPending, "the owner's stop ends the loop")
    }

    await runner.check("Five connected displays prepare the first four instead of blocking pairing") {
        let inventory = (1...5).map { syntheticDisplay(UInt32($0)) }
        var loads = 0
        let recorder = KeepAwakeRecorder()
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses,
                                   loadRemoteKey: { loads += 1; return key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { inventory }, liveSession: { available }, keepAwake: recorder.hold)
        model.start()
        runner.expect(model.busy && !model.sharing && !model.restartPending, "capture preparation starts without waiting for a display to disconnect")
        runner.expectEqual(loads, 1, "pairing setup is reached")
        runner.expectEqual(model.availableDisplays.map(\.id), [1, 2, 3, 4, 5], "every source remains available to choose")
        runner.expectEqual(model.displays.map(\.id), [1, 2, 3, 4], "the automatic selection stays within the wire limit")
        runner.expectEqual((model.sessionInventory ?? []).map(\.id), [1, 2, 3, 4], "only selected displays belong to this session")
        runner.expect(model.canStopSharing, "a preparing host remains stoppable")
        await waitUntil(seconds: 1) { gate.wasEntered }
        runner.expect(gate.wasEntered, "capture preparation is actually entered, rather than only reported")
        model.stop()
        gate.release()
        await drainMainActor()
        runner.expect(!model.busy && !model.restartPending, "an abandoned preparation stays stopped")
    }

    await runner.check("An unselected fifth display does not interrupt sharing and a selected loss rebuilds it") {
        var inventory = (1...4).map { syntheticDisplay(UInt32($0)) }
        var loads = 0
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses,
                                   loadRemoteKey: { loads += 1; return key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { inventory }, liveSession: { available }, keepAwake: KeepAwakeRecorder().hold)
        model.start()
        let preparedInventory = model.sessionInventory
        inventory.append(syntheticDisplay(5))
        model.displayConfigurationChanged()
        runner.expect(model.busy && !model.restartPending, "an unrelated extra source leaves preparation in place")
        runner.expectEqual(model.sessionInventory, preparedInventory, "the shared screen set is unchanged")
        runner.expectEqual(model.availableDisplays.map(\.id), [1, 2, 3, 4, 5], "the new source is still offered for selection")
        runner.expectEqual(loads, 1, "an unselected source does not restart pairing")
        inventory.removeAll { $0.id == 2 }
        model.displayConfigurationChanged()
        runner.expect(!model.busy && model.restartPending, "losing a selected source schedules a rebuilt session")
        runner.expectEqual(model.displays.map(\.id), [1, 3, 4, 5], "automatic selection fills the available four slots")
        runner.expect(!model.controlEnabled, "rebuilding does not grant input")
        model.stop()
        gate.release()
        await drainMainActor()
    }

    await runner.check("An owner's stop gives the next run a fresh recovery budget") {
        let clock = ManualClock()
        let recorder = KeepAwakeRecorder()
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { [syntheticDisplay(1)] }, liveSession: { available },
                                   keepAwake: recorder.hold, uptime: { clock.now })
        let interrupted = CaptureFailure(NSError(domain: SCStreamErrorDomain, code: -3821))
        recorder.hold.hold()
        model.sharing = true
        model.captureEnded(interrupted)
        clock.advance(by: limit)
        model.captureEnded(interrupted)
        runner.expect(!recorder.hold.isHeld, "the failing run used up its keep-awake window")
        model.stop()  // the owner stops, fixes the cause and starts again
        model.start()
        runner.expect(model.busy, "the new session is being prepared")
        recorder.hold.hold()  // as the new session holds the Mac awake
        model.captureEnded(interrupted)  // and fails within its first minute
        runner.expect(recorder.hold.isHeld, "the new run gets its own keep-awake window")
        runner.expect(model.status.hasSuffix("Retrying in 2 s."), "and the prompt first retry, got: \(model.status)")
        model.stop()
        gate.release()
        await drainMainActor()
    }

    await runner.check("An explicit oversubscribed capture failure resets the recovery budget before a bounded selection resumes") {
        let clock = ManualClock()
        let inventory = (1...5).map { syntheticDisplay(UInt32($0)) }
        var loads = 0
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses,
                                   loadRemoteKey: { loads += 1; return key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { throw CheckError.preparationAbandoned },
                                   inventory: { inventory }, liveSession: { available },
                                   keepAwake: KeepAwakeRecorder().hold, uptime: { clock.now })
        let interrupted = CaptureFailure(NSError(domain: SCStreamErrorDomain, code: -3821))
        model.start()
        await drainMainActor()
        for _ in 0..<5 { model.captureEnded(interrupted) }
        clock.advance(by: limit)
        model.captureEnded(interrupted)
        runner.expect(model.status.hasSuffix("Retrying in 30 s. This Mac is no longer kept awake while it retries."),
                      "the failing run is at the ceiling and past its window, got: \(model.status)")
        // This failure cannot come from the normal selection path, but a capture-side invariant
        // violation must still stop that run safely and give the next selected run a fresh budget.
        model.captureEnded(CaptureFailure(DisplayLimitExceeded(count: 5)))
        runner.expect(!model.busy && !model.sharing && !model.restartPending, "the impossible capture is ended")
        clock.advance(by: CompanionModel.selfHealInterval + 1)
        model.selfHealRemoteHosting()
        await waitUntil(seconds: 3) { loads >= 2 && !model.busy }
        runner.expect(loads >= 2, "the bounded selection resumes even with five displays still attached")
        runner.expectEqual(model.displays.map(\.id), [1, 2, 3, 4], "the resumed selection stays bounded")
        runner.expect(model.status.hasSuffix("Retrying in 2 s."), "a subsequent failure starts a fresh run, got: \(model.status)")
        model.stop()
    }

    await runner.check("Five display selection still honors every host security pause and its resume") {
        let clock = ManualClock()
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { (1...5).map { syntheticDisplay(UInt32($0)) } }, liveSession: { available },
                                   keepAwake: KeepAwakeRecorder().hold, uptime: { clock.now })
        model.start()
        runner.expect(model.busy, "five sources do not prevent initial preparation")
        let pairs: [(HostSessionNotice, HostSessionNotice)] = [(.locked, .unlocked), (.willSleep, .didWake),
                                                               (.screensSlept, .screensWoke), (.sessionResigned, .sessionActivated)]
        for (pause, answer) in pairs {
            model.receiveSessionNotice(pause)
            runner.expect(model.status.hasPrefix("Remote sharing paused"), "\(pause) is reported, got: \(model.status)")
            runner.expect(!model.busy && !model.sharing && !model.restartPending, "\(pause) cancels preparation and any restart")
            model.receiveSessionNotice(answer)
            runner.expect(model.restartPending, "\(answer) resumes the selected displays without requiring a disconnect")
        }
        model.receiveSessionNotice(.locked)
        clock.advance(by: HostSessionFlags.noticeGraceSeconds + CompanionModel.selfHealInterval)
        model.selfHealRemoteHosting()
        runner.expect(model.restartPending, "the live unlocked session can reconcile a missed unlock notice")
        model.stop()
        gate.release()
        await drainMainActor()
    }

    await runner.check("Display selection and self-healing preserve the owner's latest remote-access feedback") {
        let clock = ManualClock()
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses, loadRemoteKey: { key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { (1...5).map { syntheticDisplay(UInt32($0)) } }, liveSession: { available },
                                   keepAwake: KeepAwakeRecorder().hold, uptime: { clock.now })
        model.start()
        runner.expectEqual(model.configureRemoteAccess(address: "192.168.1.20", allowControl: false, keepAwake: true), .refused,
                           "a private address absent from this Mac is still refused")
        let feedback = model.remoteFeedback
        runner.expect(feedback?.message.contains("private VPN addresses") == true && feedback?.message.contains("100.64.0.1") == true && feedback?.fix == nil,
                      "the refusal is actionable, got: \(feedback?.message ?? "nothing")")
        model.receiveSessionNotice(.locked)
        clock.advance(by: HostSessionFlags.noticeGraceSeconds + CompanionModel.selfHealInterval)
        model.selfHealRemoteHosting()
        runner.expect(model.restartPending, "selection allows the healthy host to resume")
        runner.expectEqual(model.remoteFeedback, feedback, "the backstop leaves the owner's answer in place")
        model.displayConfigurationChanged()
        runner.expectEqual(model.remoteFeedback, feedback, "refreshing display selection also leaves it in place")
        model.receiveSessionNotice(.didWake)
        runner.expectEqual(model.remoteFeedback, feedback, "so does a wake that ended no pause")
        model.stop()
        gate.release()
        await drainMainActor()
    }

    await runner.check("Stop Sharing disarms recovery with five sources and publishes that change") {
        let clock = ManualClock()
        var inventory = (1...5).map { syntheticDisplay(UInt32($0)) }
        var loads = 0
        let gate = PreparationGate()
        let model = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, remoteConfiguration: checkRemoteConfiguration, localAddresses: checkLocalAddresses,
                                   loadRemoteKey: { loads += 1; return key },
                                   saveRemoteConfiguration: { _ in },
                                   contentProvider: { await gate.waitUntilReleased(); throw CheckError.preparationAbandoned },
                                   inventory: { inventory }, liveSession: { available },
                                   keepAwake: KeepAwakeRecorder().hold, uptime: { clock.now })
        runner.expect(!model.autoRecoveryArmed && !model.canStopSharing, "a host nobody started has nothing to stop")
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        model.start()
        runner.expect(model.busy && !model.restartPending, "the selected four enter preparation")
        runner.expect(model.canStopSharing, "a preparing host can be stopped")
        runner.expect(publications > 0, "that change reaches the window")
        publications = 0
        model.stop()
        runner.expect(!model.autoRecoveryArmed && !model.canStopSharing, "Stop Sharing disarms it")
        runner.expect(publications > 0, "the window is told")
        inventory.removeLast()
        clock.advance(by: CompanionModel.selfHealInterval + 1)
        model.selfHealRemoteHosting()
        runner.expect(!model.restartPending && loads == 1, "removing the extra display does not override the owner's Stop")
        gate.release()
        await drainMainActor()
        let local = CompanionModel(loadLANKey: { PairingKey.generate() }, saveLANKey: { _ in }, saveLANConfiguration: { _ in }, saveRemoteConfiguration: { _ in }, contentProvider: { throw CheckError.preparationAbandoned }, inventory: { [syntheticDisplay(1)] })
        runner.expect(!local.autoRecoveryArmed, "a nearby host nobody started is not armed")
        local.stop()
    }
}
