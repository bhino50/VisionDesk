import DeskCore
import Foundation
import XCTest

final class SetupReadinessTests: XCTestCase {
    private func snapshot(displays: Int = 1,
                          screen: Bool = true,
                          accessibility: Bool = false,
                          preparing: Bool = false,
                          sharing: Bool = false,
                          connected: Bool = false,
                          control: Bool = false,
                          testMode: Bool = true,
                          key: Bool = false) -> SetupSnapshot {
        SetupSnapshot(displayCount: displays, screenRecordingAllowed: screen, accessibilityAllowed: accessibility,
                      preparing: preparing, sharing: sharing, connected: connected, controlEnabled: control,
                      testMode: testMode, pairingKeyReady: key)
    }

    func testGuidanceWalksTheSetupChainFromNoDisplaysToAConnectedHeadset() {
        var state = snapshot(displays: 0, screen: false)
        var readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.displays.status, .actionNeeded)
        XCTAssertEqual(readiness.primaryNextStep, readiness.displays.nextStep)

        state.displayCount = 1
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.displays.status, .ready)
        XCTAssertEqual(readiness.screenRecording.status, .actionNeeded)
        XCTAssertEqual(readiness.primaryNextStep, readiness.screenRecording.nextStep)

        state.screenRecordingAllowed = true
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.screenRecording.status, .ready)
        XCTAssertEqual(readiness.sharing.status, .actionNeeded)
        XCTAssertEqual(readiness.primaryNextStep, readiness.sharing.nextStep)

        state.preparing = true
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.status(of: .viewing), .inProgress)
        XCTAssertNotEqual(readiness.sharing.status, .ready)
        XCTAssertEqual(readiness.primaryNextStep, SetupReadiness.startingMessage)

        state.displayCount = 0
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.primaryNextStep, readiness.displays.nextStep,
                       "A blocker earlier in the chain outranks a step that is still starting")

        state.displayCount = 1
        state.preparing = false
        state.sharing = true
        state.pairingKeyReady = true
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.sharing.status, .ready)
        XCTAssertEqual(readiness.headset.status, .actionNeeded)
        XCTAssertEqual(readiness.primaryNextStep, readiness.headset.nextStep)

        state.connected = true
        state.pairingKeyReady = false
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.status(of: .viewing), .ready)
        XCTAssertEqual(readiness.primaryNextStep, readiness.testInput.nextStep)
    }

    func testStoppedCaptureAndMissingSessionsAreNeverReportedAsReady() {
        let stopped = snapshot(displays: 4, accessibility: true, sharing: false, connected: false,
                               control: true, testMode: false)
        let afterStop = SetupReadiness(snapshot: stopped)
        XCTAssertEqual(afterStop.sharing.status, .actionNeeded)
        XCTAssertEqual(afterStop.headset.status, .actionNeeded)
        XCTAssertNotEqual(afterStop.status(of: .viewing), .ready)
        XCTAssertNotEqual(afterStop.macControl.status, .ready)
        XCTAssertNotEqual(afterStop.status(of: .macControl), .ready)

        let unpaired = snapshot(displays: 2, sharing: true, connected: false, control: true, key: true)
        let waiting = SetupReadiness(snapshot: unpaired)
        XCTAssertEqual(waiting.sharing.status, .ready)
        XCTAssertNotEqual(waiting.headset.status, .ready)
        XCTAssertNotEqual(waiting.status(of: .viewing), .ready)
        XCTAssertNotEqual(waiting.testInput.status, .ready)
        XCTAssertEqual(waiting.primaryNextStep, waiting.headset.nextStep)

        let sessionWithoutCapture = snapshot(sharing: false, connected: true, control: true)
        let inconsistent = SetupReadiness(snapshot: sessionWithoutCapture)
        XCTAssertNotEqual(inconsistent.headset.status, .ready)
        XCTAssertNotEqual(inconsistent.testInput.status, .ready)
    }

    func testTestInputAndRealControlStayOnSeparateTracks() {
        var state = snapshot(displays: 2, accessibility: true, sharing: true, connected: true,
                             control: true, testMode: true)
        var readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.testInput.status, .ready)
        XCTAssertEqual(readiness.status(of: .testInput), .ready)
        XCTAssertEqual(readiness.accessibility.status, .ready)
        XCTAssertEqual(readiness.macControl.status, .inactive)
        XCTAssertEqual(readiness.status(of: .macControl), .inactive,
                       "A granted Accessibility permission must not make real control look live in test mode")
        XCTAssertNil(readiness.primaryNextStep)

        // The model revokes input whenever the mode flips, so mirror that.
        state.testMode = false
        state.controlEnabled = false
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.testInput.status, .inactive)
        XCTAssertEqual(readiness.macControl.status, .actionNeeded)
        XCTAssertEqual(readiness.primaryNextStep, readiness.macControl.nextStep)

        state.controlEnabled = true
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.macControl.status, .ready)
        XCTAssertEqual(readiness.status(of: .macControl), .ready)
        XCTAssertEqual(readiness.testInput.status, .inactive)
        XCTAssertNil(readiness.primaryNextStep)
    }

    func testAccessibilityPermissionTransitionsDriveRealControlGuidance() {
        var state = snapshot(accessibility: false, sharing: true, connected: true, testMode: true)
        var readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.accessibility.status, .inactive)
        XCTAssertNotNil(readiness.accessibility.nextStep)
        XCTAssertEqual(readiness.primaryNextStep, readiness.testInput.nextStep)

        state.testMode = false
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.accessibility.status, .actionNeeded)
        XCTAssertEqual(readiness.primaryNextStep, readiness.accessibility.nextStep)

        state.accessibilityAllowed = true
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.accessibility.status, .ready)
        XCTAssertEqual(readiness.primaryNextStep, readiness.macControl.nextStep)

        state.controlEnabled = true
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.macControl.status, .ready)

        // Permission pulled in System Settings while input is still marked on.
        state.accessibilityAllowed = false
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.accessibility.status, .actionNeeded)
        XCTAssertEqual(readiness.macControl.status, .actionNeeded)
        XCTAssertNotEqual(readiness.status(of: .macControl), .ready)
    }

    func testScreenRecordingPermissionLossBlocksViewingWithoutDisturbingTestInput() {
        var state = snapshot(displays: 2, sharing: true, connected: true, control: true, testMode: true)
        var readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.status(of: .viewing), .ready)
        XCTAssertEqual(readiness.testInput.status, .ready)

        state.screenRecordingAllowed = false
        readiness = SetupReadiness(snapshot: state)
        XCTAssertEqual(readiness.screenRecording.status, .actionNeeded)
        XCTAssertEqual(readiness.status(of: .viewing), .actionNeeded)
        XCTAssertEqual(readiness.primaryNextStep, readiness.screenRecording.nextStep)
        XCTAssertEqual(readiness.testInput.status, .ready,
                       "Test input state is observed separately from capture permission")
    }

    func testOneDisplayWorksWhileTheFourDisplayGoalStaysVisible() throws {
        let single = SetupReadiness(snapshot: snapshot(displays: 1, sharing: true, connected: true))
        XCTAssertEqual(single.displays.status, .ready)
        XCTAssertEqual(single.status(of: .viewing), .ready, "A single display must not block viewing")
        let singleNote = try XCTUnwrap(single.displayGoalNote)
        XCTAssertTrue(singleNote.contains("other 3"), "The reminder must name the three missing monitors")

        let pair = SetupReadiness(snapshot: snapshot(displays: 2, sharing: true, connected: true))
        let pairNote = try XCTUnwrap(pair.displayGoalNote)
        XCTAssertNotEqual(pairNote, singleNote)
        XCTAssertEqual(pair.displays.status, .ready)

        let four = SetupReadiness(snapshot: snapshot(displays: 4, sharing: true, connected: true))
        XCTAssertEqual(four.displays.status, .ready)
        XCTAssertNil(four.displayGoalNote, "No reminder once the four-display goal is met")

        let five = SetupReadiness(snapshot: snapshot(displays: 5, sharing: true, connected: true))
        XCTAssertEqual(five.displays.status, .actionNeeded)
        XCTAssertNotEqual(five.status(of: .viewing), .ready)
        XCTAssertEqual(five.primaryNextStep, five.displays.nextStep)
        XCTAssertTrue(try XCTUnwrap(five.displays.nextStep).contains("Disconnect 1 display "))
        XCTAssertNil(five.displayGoalNote)

        let none = SetupReadiness(snapshot: snapshot(displays: 0, sharing: true, connected: true))
        XCTAssertEqual(none.displays.status, .actionNeeded)
        XCTAssertNil(none.displayGoalNote)
    }

    func testEveryObservableCombinationKeepsReadyLabelsAndNextStepsHonest() {
        for count in [0, 1, 3, 4, 5] {
            for mask in 0..<128 {
                assertInvariants(SetupSnapshot(displayCount: count,
                                               screenRecordingAllowed: mask & 1 != 0,
                                               accessibilityAllowed: mask & 2 != 0,
                                               preparing: mask & 4 != 0,
                                               sharing: mask & 8 != 0,
                                               connected: mask & 16 != 0,
                                               controlEnabled: mask & 32 != 0,
                                               testMode: mask & 64 != 0,
                                               pairingKeyReady: mask & 8 != 0))
            }
        }
    }

    private func assertInvariants(_ state: SetupSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        let readiness = SetupReadiness(snapshot: state)
        let live = state.sharing && state.connected && !state.preparing
        XCTAssertEqual(Set(readiness.checks.map(\.id)).count, readiness.checks.count,
                       "Duplicate check identity", file: file, line: line)

        if readiness.status(of: .viewing) == .ready {
            let usableDisplays = (1...SetupReadiness.maximumSharedDisplayCount).contains(state.displayCount)
            XCTAssertTrue(live && state.screenRecordingAllowed && usableDisplays,
                          "Viewing reported ready for \(state)", file: file, line: line)
        }
        if readiness.testInput.status == .ready {
            XCTAssertTrue(live && state.testMode && state.controlEnabled,
                          "Test input reported ready for \(state)", file: file, line: line)
        }
        if readiness.macControl.status == .ready {
            XCTAssertTrue(live && !state.testMode && state.controlEnabled && state.accessibilityAllowed,
                          "Mac control reported ready for \(state)", file: file, line: line)
        }
        for check in readiness.checks where check.status == .actionNeeded {
            XCTAssertFalse(check.detail.isEmpty, "Empty detail for \(check.id)", file: file, line: line)
            XCTAssertFalse(check.nextStep?.isEmpty ?? true, "Missing next step for \(check.id)", file: file, line: line)
        }
        if readiness.primaryNextStep == nil {
            XCTAssertFalse(readiness.checks.contains { $0.status == .actionNeeded || $0.status == .inProgress },
                           "Pending work without guidance for \(state)", file: file, line: line)
        }
    }
}
