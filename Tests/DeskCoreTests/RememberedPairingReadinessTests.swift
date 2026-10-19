import DeskCore
import Foundation
import XCTest

/// Setup guidance for a host with remembered pairing, where a saved headset connects with the key
/// it stored, and the companion control names that every piece of guidance quotes.
final class RememberedPairingReadinessTests: XCTestCase {
    func testPersistentNearbyPairingUsesTheNearbyListInsteadOfADefaultPort() throws {
        let snapshot = SetupSnapshot(displayCount: 1, screenRecordingAllowed: true,
                                     sharing: true, pairingKeyReady: true,
                                     rememberedPairing: true, nearbyPairing: true)
        let next = try XCTUnwrap(SetupReadiness(snapshot: snapshot).primaryNextStep)
        XCTAssertTrue(next.contains("choose this Mac in the nearby list"), next)
        XCTAssertTrue(next.contains("pairing key shown on this Mac"), next)
        XCTAssertFalse(next.contains("Connect by Address"), next)
    }

    private func remembered(displays: Int = 2,
                            screen: Bool = true,
                            accessibility: Bool = true,
                            preparing: Bool = false,
                            sharing: Bool = true,
                            connected: Bool = false,
                            control: Bool = false,
                            testMode: Bool = false,
                            key: Bool = false) -> SetupSnapshot {
        SetupSnapshot(displayCount: displays, screenRecordingAllowed: screen, accessibilityAllowed: accessibility,
                      preparing: preparing, sharing: sharing, connected: connected, controlEnabled: control,
                      testMode: testMode, pairingKeyReady: key, rememberedPairing: true)
    }

    /// Every observable combination for one pairing mode, with the key flag varied independently.
    private func everySnapshot(remembered: Bool) -> [SetupSnapshot] {
        [0, 1, 4, 5].flatMap { count in
            (0..<256).map { mask in
                SetupSnapshot(displayCount: count,
                              screenRecordingAllowed: mask & 1 != 0,
                              accessibilityAllowed: mask & 2 != 0,
                              preparing: mask & 4 != 0,
                              sharing: mask & 8 != 0,
                              connected: mask & 16 != 0,
                              controlEnabled: mask & 32 != 0,
                              testMode: mask & 64 != 0,
                              pairingKeyReady: mask & 128 != 0,
                              rememberedPairing: remembered)
            }
        }
    }

    /// One-session advice that a remembered host must never be given.
    private func assertNoFreshKeyAdvice(_ readiness: SetupReadiness, _ context: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        for check in readiness.checks {
            for text in [check.detail, check.nextStep ?? ""] {
                XCTAssertFalse(text.contains("one-session"), "\(check.id) for \(context): \(text)", file: file, line: line)
                XCTAssertFalse(text.contains("fresh"), "\(check.id) for \(context): \(text)", file: file, line: line)
                XCTAssertFalse(text.contains("Stop Sharing"), "\(check.id) for \(context): \(text)", file: file, line: line)
            }
        }
    }

    func testTheFlagDefaultsOffSoExistingCallersKeepOneSessionGuidance() {
        let legacy = SetupSnapshot(displayCount: 2, screenRecordingAllowed: true, sharing: true)
        XCTAssertFalse(legacy.rememberedPairing)
        XCTAssertEqual(legacy, SetupSnapshot(displayCount: 2, screenRecordingAllowed: true, sharing: true,
                                             rememberedPairing: false))
        let readiness = SetupReadiness(snapshot: legacy)
        XCTAssertEqual(readiness.headset.status, .actionNeeded)
        XCTAssertEqual(readiness.headset.nextStep,
                       "Choose Stop Sharing, then Start Sharing & Control for a fresh one-session key.")
        XCTAssertEqual(readiness.primaryNextStep, readiness.headset.nextStep)
    }

    func testARememberedHostWaitingForItsHeadsetIsAWaitNotABlocker() throws {
        let readiness = SetupReadiness(snapshot: remembered())
        XCTAssertEqual(readiness.sharing.status, .ready)
        XCTAssertEqual(readiness.headset.status, .inProgress)
        XCTAssertEqual(readiness.status(of: .viewing), .inProgress, "Waiting is neither ready nor blocked")
        XCTAssertEqual(readiness.status(of: .viewing).label, "Waiting")
        XCTAssertEqual(readiness.headline, "Sharing is running. Waiting for the remembered Vision Pro to connect.")
        XCTAssertEqual(readiness.headset.detail, "Sharing is running and waiting for the remembered Vision Pro to connect.")
        let next = try XCTUnwrap(readiness.primaryNextStep)
        XCTAssertEqual(next, readiness.headset.nextStep, "The wait outranks input steps that depend on it")
        XCTAssertEqual(next, "On Vision Pro, open VisionDesk and choose this Mac's saved card. "
                           + "To pair a different headset, choose Show Pairing Key.")
        assertNoFreshKeyAdvice(readiness, "remembered host waiting")
    }

    func testAKeyOnScreenAddsFirstPairingStepsWithoutAskingForANewKey() throws {
        let readiness = SetupReadiness(snapshot: remembered(key: true))
        XCTAssertEqual(readiness.headset.status, .inProgress)
        XCTAssertEqual(readiness.headline, "Sharing is running. Waiting for the remembered Vision Pro to connect.")
        let next = try XCTUnwrap(readiness.primaryNextStep)
        XCTAssertTrue(next.hasPrefix("On Vision Pro, open VisionDesk and choose this Mac's saved card. "), next)
        XCTAssertTrue(next.contains("the pairing key shown on this Mac"), next)
        XCTAssertTrue(next.contains("choose Connect by Address"), next)
        XCTAssertTrue(next.hasSuffix("the pairing key shown on this Mac."), next)
        XCTAssertFalse(next.contains("Remember this Mac"), next)
        assertNoFreshKeyAdvice(readiness, "remembered host with its key on screen")
    }

    func testAConnectedRememberedHeadsetIsLiveExactlyAsBefore() {
        let controlled = SetupReadiness(snapshot: remembered(connected: true, control: true))
        XCTAssertEqual(controlled.headset.status, .ready)
        XCTAssertEqual(controlled.status(of: .viewing), .ready)
        XCTAssertEqual(controlled.headline, "Sharing session connected. Mac control is enabled.")
        XCTAssertNil(controlled.primaryNextStep)

        let viewing = SetupReadiness(snapshot: remembered(connected: true))
        XCTAssertEqual(viewing.headline, "Sharing session connected. Input is not enabled.")
        XCTAssertEqual(viewing.primaryNextStep, "Choose Enable Mac Control.")
    }

    func testStartingCaptureStillReadsAsStarting() {
        let readiness = SetupReadiness(snapshot: remembered(preparing: true, sharing: false))
        XCTAssertEqual(readiness.status(of: .viewing), .inProgress)
        XCTAssertEqual(readiness.headline, "Starting capture for your displays.")
        XCTAssertEqual(readiness.primaryNextStep, SetupReadiness.startingMessage)
    }

    func testAStoppedRememberedHostAsksToStartSharingByItsCurrentName() {
        let readiness = SetupReadiness(snapshot: remembered(sharing: false))
        XCTAssertEqual(readiness.sharing.status, .actionNeeded)
        XCTAssertEqual(readiness.primaryNextStep, "Choose Start Sharing & Control.")
        XCTAssertEqual(readiness.headset.status, .actionNeeded)
        XCTAssertEqual(readiness.headset.nextStep,
                       "Choose Start Sharing & Control, then open VisionDesk on Vision Pro and choose this Mac's saved card.")
        assertNoFreshKeyAdvice(readiness, "stopped remembered host")
    }

    func testAnEarlierBlockerStillOutranksTheWait() {
        let tooMany = SetupReadiness(snapshot: remembered(displays: 5))
        XCTAssertEqual(tooMany.status(of: .viewing), .actionNeeded)
        XCTAssertEqual(tooMany.primaryNextStep, tooMany.displays.nextStep)

        let noRecording = SetupReadiness(snapshot: remembered(screen: false))
        XCTAssertEqual(noRecording.status(of: .viewing), .actionNeeded)
        XCTAssertEqual(noRecording.primaryNextStep, noRecording.screenRecording.nextStep)
        XCTAssertEqual(noRecording.headline, "Not ready to view this Mac in the headset yet.")
    }

    func testGuidanceNamesTheCompanionControlsByTheirCurrentTitles() {
        let stopped = SetupReadiness(snapshot: SetupSnapshot(displayCount: 1, screenRecordingAllowed: true))
        XCTAssertEqual(stopped.sharing.nextStep, "Choose Start Sharing & Control.")
        let keyless = SetupReadiness(snapshot: SetupSnapshot(displayCount: 1, screenRecordingAllowed: true, sharing: true))
        XCTAssertEqual(keyless.headset.nextStep,
                       "Choose Stop Sharing, then Start Sharing & Control for a fresh one-session key.")
        let keyed = SetupReadiness(snapshot: SetupSnapshot(displayCount: 1, screenRecordingAllowed: true, sharing: true,
                                                           pairingKeyReady: true))
        XCTAssertEqual(keyed.headset.nextStep,
                       "On Vision Pro, open VisionDesk and enter the one-session key shown under Sharing & Pairing.")

        for snapshot in everySnapshot(remembered: false) + everySnapshot(remembered: true) {
            for check in SetupReadiness(snapshot: snapshot).checks {
                for text in [check.detail, check.nextStep ?? ""] {
                    XCTAssertFalse(text.contains("Start Sharing & Pairing"),
                                   "\(check.id) names a control the companion no longer has: \(text)")
                }
            }
        }
    }

    func testEveryRememberedCombinationStaysHonestAndNeverAsksForAFreshKey() {
        for snapshot in everySnapshot(remembered: true) {
            let readiness = SetupReadiness(snapshot: snapshot)
            let live = snapshot.sharing && snapshot.connected && !snapshot.preparing
            if readiness.status(of: .viewing) == .ready || readiness.headset.status == .ready {
                XCTAssertTrue(live, "Reported ready without a live headset: \(snapshot)")
            }
            if snapshot.sharing && !snapshot.connected && !snapshot.preparing {
                XCTAssertEqual(readiness.headset.status, .inProgress, "\(snapshot)")
                XCTAssertTrue(readiness.headset.nextStep?.contains("this Mac's saved card") == true, "\(snapshot)")
            }
            assertNoFreshKeyAdvice(readiness, "\(snapshot)")
            for check in readiness.checks where check.status == .actionNeeded {
                XCTAssertFalse(check.nextStep?.isEmpty ?? true, "Missing next step for \(check.id) in \(snapshot)")
            }
            if readiness.primaryNextStep == nil {
                XCTAssertFalse(readiness.checks.contains { $0.status == .actionNeeded || $0.status == .inProgress },
                               "Pending work without guidance for \(snapshot)")
            }
        }
    }
}
