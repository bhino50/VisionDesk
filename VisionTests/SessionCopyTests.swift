import XCTest
@testable import VisionDesk

/// The sentences the client shows about its connection and its screens. Each one has to say
/// what is true and what to do next, and must never offer something the session cannot do.
final class SessionCopyTests: XCTestCase {
    /// A wrong key and a Mac that never answered both end in the handshake running out of time,
    /// so the advice covers both, in the words the headset uses, for the way the Mac was reached.
    func testAFailedFirstAttemptNamesTheMacTheReasonAndTheWayForward() {
        let timeout = "Pairing timed out. Check the key and local network."
        XCTAssertEqual(
            SessionCopy.couldNotConnect(to: "Studio", reason: timeout, route: .nearby),
            "Couldn't connect to Studio. Pairing didn't finish in time. Check that the pairing key you entered matches the one on your Mac and that your Mac is still sharing, then connect again."
        )
        XCTAssertEqual(
            SessionCopy.couldNotConnect(to: "100.64.0.42", reason: timeout, route: .address),
            "Couldn't connect to 100.64.0.42. Pairing didn't finish in time. Check the address and pairing key you entered, and that your Mac is awake and reachable on your network or VPN, then connect again."
        )
        XCTAssertTrue(SessionCopy.couldNotConnect(to: " \n", reason: "R.", route: .nearby)
            .hasPrefix("Couldn't connect to your Mac. R. "), "A reason it does not know is shown as it is.")
    }

    /// A Mac reached in this session has been lost. A saved Mac that has not answered yet has
    /// not been, and saying it was would send the wearer looking for a fault that is not there.
    func testARetrySaysWhetherAnythingWasLost() {
        XCTAssertEqual(SessionCopy.retrying("Studio", inSeconds: 1, attempt: 1, of: 5, everConnected: true),
                       "Lost the connection to Studio. Trying again in 1s (attempt 1 of 5).")
        XCTAssertEqual(SessionCopy.retrying("Studio", inSeconds: 2, attempt: 2, of: 5, everConnected: false),
                       "Couldn't reach Studio yet. Trying again in 2s (attempt 2 of 5).")
        XCTAssertEqual(SessionCopy.reconnecting(to: " ", attempt: 3, of: 5),
                       "Reconnecting to your Mac (attempt 3 of 5).")
    }

    /// Giving up on a saved Mac that never answered names the one fix for a key that changed
    /// when remote access was reset on the Mac.
    func testGivingUpSaysWhatToDoNext() {
        XCTAssertEqual(SessionCopy.gaveUp(on: "Studio", everConnected: true),
                       "Could not reach Studio after several tries. Connect again once your Mac is awake and on the network.")
        let saved = SessionCopy.gaveUp(on: "Studio", everConnected: false)
        XCTAssertTrue(saved.hasPrefix("Could not reach Studio after several tries. "), saved)
        XCTAssertTrue(saved.contains("choose More, then Forget This Mac, and pair with the new key"), saved)
    }

    /// The control card offers exactly one control action, and only one the model would carry
    /// out: Stop while the Mac's grant stands, silent or not; a request while there is none; and
    /// nothing while this headset's Stop is unanswered, which outranks every other state.
    func testTheControlCardOffersOnlyTheActionThatApplies() {
        func summary(enabled: Bool = false, pending: Bool = false, responsive: Bool = true,
                     status: String = "") -> SessionCopy.ControlSummary {
            SessionCopy.controlSummary(isControlEnabled: enabled, isStopPending: pending,
                                       isMacResponsive: responsive, macStatus: status)
        }
        let controlling = summary(enabled: true, status: "Mac control enabled")
        XCTAssertEqual(controlling.title, "You're in control")
        XCTAssertEqual(controlling.tone, .active)
        XCTAssertEqual(controlling.action, .stopControl)

        for responsive in [true, false] {
            for enabled in [true, false] {
                let stopped = summary(enabled: enabled, pending: true, responsive: responsive)
                XCTAssertEqual(stopped.title, "Control stopped")
                XCTAssertEqual(stopped.action, .none, "Nothing is offered until the Mac answers the Stop.")
            }
        }

        let paused = summary(enabled: true, responsive: false)
        XCTAssertEqual(paused.title, "Control paused")
        XCTAssertEqual(paused.tone, .attention)
        XCTAssertEqual(paused.action, .stopControl, "A grant that still stands can still be stopped.")
        let silentViewing = summary(responsive: false)
        XCTAssertEqual(silentViewing.title, "Viewing only")
        XCTAssertEqual(silentViewing.action, .none, "A silent Mac cannot answer a request.")

        let viewing = summary(status: "Input stopped from Vision Pro.")
        XCTAssertEqual(viewing.title, "Viewing only")
        XCTAssertEqual(viewing.detail, "Input stopped from Vision Pro.", "The Mac's own answer is shown.")
        XCTAssertEqual(viewing.action, .requestControl)
        XCTAssertEqual(summary(status: " \n").detail,
                       "To use your Mac from here, enable control in VisionDesk on your Mac.")
    }

    func testTheKeyboardSaysWhyItIsPaused() {
        XCTAssertEqual(SessionCopy.keyboardPaused(isWindowActive: false, canControlMac: true, isMacResponsive: true),
                       "Keyboard paused while this window isn't active.")
        XCTAssertEqual(SessionCopy.keyboardPaused(isWindowActive: true, canControlMac: true, isMacResponsive: true),
                       "Keyboard paused. Waiting for a fresh frame from this screen before it accepts input.",
                       "Control is on, so the keyboard does not ask for it to be enabled.")
        XCTAssertEqual(SessionCopy.keyboardPaused(isWindowActive: true, canControlMac: false, isMacResponsive: true),
                       "Keyboard paused. Viewing only. Enable control in VisionDesk on your Mac.")
    }

    func testAStoppedSessionSaysHowControlComesBack() {
        XCTAssertEqual(SessionCopy.controlStoppedStatus, "Control stopped. Enable control on your Mac to resume.")
    }

    func testNotRespondingDetailCountsWholeSecondsAndOffersOnlyWhatWillHappen() {
        XCTAssertEqual(
            SessionCopy.notRespondingDetail(seconds: 6.9, willRecover: true, canReconnect: true),
            "Nothing has arrived from your Mac for 6 s. VisionDesk reconnects on its own if this continues. Choose Reconnect to try now."
        )
        XCTAssertEqual(
            SessionCopy.notRespondingDetail(seconds: 21, willRecover: false, canReconnect: true),
            "Nothing has arrived from your Mac for 21 s. Choose Reconnect to try again."
        )
        XCTAssertEqual(
            SessionCopy.notRespondingDetail(seconds: 5, willRecover: false, canReconnect: false),
            "Nothing has arrived from your Mac for 5 s. If it went to sleep or left the network, disconnect and pair again."
        )
        for odd: TimeInterval in [-3, -.infinity, .infinity, .nan] {
            XCTAssertTrue(SessionCopy.notRespondingDetail(seconds: odd, willRecover: false, canReconnect: false)
                .hasPrefix("Nothing has arrived from your Mac for 0 s."), "\(odd)")
        }
    }

    /// A display window outlives its screen. While a reconnection is under way it must say so,
    /// rather than send the wearer off to connect by hand to a Mac that is already being dialled.
    func testADisplayWindowWithoutAScreenSaysWhatIsHappening() {
        let gone = SessionCopy.displayPlaceholder(isLinked: true, isReconnecting: false, isConnecting: false, macName: "Studio")
        XCTAssertEqual(gone.title, "This display is no longer available")
        XCTAssertFalse(gone.showsProgress)

        let reconnecting = SessionCopy.displayPlaceholder(isLinked: false, isReconnecting: true, isConnecting: false, macName: "Studio")
        XCTAssertEqual(reconnecting.title, "Reconnecting to Studio…")
        XCTAssertTrue(reconnecting.showsProgress)
        XCTAssertTrue(reconnecting.detail.contains("Keep this window open"))
        XCTAssertEqual(
            SessionCopy.displayPlaceholder(isLinked: false, isReconnecting: true, isConnecting: true, macName: "Studio").title,
            "Reconnecting to Studio…", "An attempt within a reconnection is still a reconnection."
        )
        XCTAssertEqual(
            SessionCopy.displayPlaceholder(isLinked: false, isReconnecting: false, isConnecting: true, macName: "").title,
            "Connecting to your Mac…"
        )

        let idle = SessionCopy.displayPlaceholder(isLinked: false, isReconnecting: false, isConnecting: false, macName: "Studio")
        XCTAssertEqual(idle.title, "Your Mac is disconnected")
        XCTAssertFalse(idle.showsProgress)
    }

    /// A silent Mac explains every paused screen at once, so it outranks one stream's decode
    /// warning and the generic sharing advice.
    func testASilentMacExplainsEveryPausedScreen() {
        XCTAssertEqual(SessionCopy.pausedScreenDetail(decodeWarning: "Bad frame.", isMacResponsive: false),
                       "Your Mac isn't responding. Check that it's awake and on the network.")
        XCTAssertEqual(SessionCopy.pausedScreenDetail(decodeWarning: "Bad frame.", isMacResponsive: true), "Bad frame.")
        XCTAssertEqual(SessionCopy.pausedScreenDetail(decodeWarning: nil, isMacResponsive: true),
                       "Check screen sharing in VisionDesk on your Mac.")
    }

    /// The footer and the accessibility hint say what a gesture will actually do. In Pointer
    /// mode a tap clicks where the pointer already is, so until it has been placed the hint
    /// says how to place it rather than promising a click that will be refused.
    func testTheControlHintMatchesWhatTheScreenWillDo() {
        func hint(display: Bool = true, mac: Bool = true, responsive: Bool = true,
                  mode: ScreenInteractionMode = .pointer, placed: Bool = true) -> String {
            SessionCopy.controlHint(canControlDisplay: display, canControlMac: mac, isMacResponsive: responsive,
                                    mode: mode, pointerPlaced: placed)
        }
        XCTAssertEqual(hint(placed: false), SessionCopy.pointerPlacementHint)
        XCTAssertEqual(hint(placed: true), ScreenInteractionMode.pointer.instruction)
        for mode in [ScreenInteractionMode.interact, .scroll] {
            XCTAssertEqual(hint(mode: mode, placed: false), mode.instruction,
                           "\(mode) pinches place the pointer themselves.")
        }
        XCTAssertEqual(hint(display: false), "Waiting for a fresh frame from this screen before it accepts input.")
        XCTAssertEqual(hint(display: false, responsive: false),
                       "Your Mac isn't responding, so this screen can't accept input yet.")
        XCTAssertEqual(hint(display: false, mac: false), "Viewing only. Enable control in VisionDesk on your Mac.")
        XCTAssertEqual(hint(display: false, mac: false, responsive: false),
                       "Viewing only. Enable control in VisionDesk on your Mac.")
    }

    func testARefusedAssistiveClickNamesTheActionThatPlacesThePointer() {
        XCTAssertTrue(SessionCopy.assistivePlacementHint.hasPrefix("Nothing was clicked."))
        XCTAssertTrue(SessionCopy.assistivePlacementHint.contains(SessionCopy.placePointerActionName))
    }

    func testAnUnnamedMacIsStillNamed() {
        XCTAssertEqual(SessionCopy.macName("  Studio \n"), "Studio")
        XCTAssertEqual(SessionCopy.macName(""), "your Mac")
        XCTAssertEqual(SessionCopy.macName(" \t"), "your Mac")
    }
}
