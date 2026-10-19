import XCTest
@testable import DeskTransport
@testable import VisionDesk

/// The words for the way in: the line under the pairing key, why a connection did not work, and
/// what the nearby list says while it is empty. Failures here never print a key: keys are only
/// ever compared, and messages name the case rather than the text.
final class PairingCopyTests: XCTestCase {
    // MARK: Pairing key

    /// The hint and `PairingKey(string:)` agree on what a whole key is, including the forms the
    /// Mac's display value can be retyped in.
    func testTheKeyHintAgreesWithThePairingKeyParser() {
        let key = PairingKey.generate()
        let display = key.displayValue
        let compact = display.replacingOccurrences(of: "-", with: "")
        let spaced = compact.enumerated().map { $0.offset % 4 == 3 ? "\($0.element) " : "\($0.element)" }.joined()
        let forms = [display, display.lowercased(), compact, spaced, " \(display)\n", compact.replacingOccurrences(of: "A", with: "a")]
        for (index, form) in forms.enumerated() {
            XCTAssertEqual(SessionCopy.keyEntry(form), .complete, "form \(index)")
            XCTAssertNotNil(PairingKey(string: form), "form \(index)")
        }

        XCTAssertEqual(SessionCopy.keyEntry(""), .empty)
        XCTAssertEqual(SessionCopy.keyEntry(" - \n"), .empty)
        XCTAssertEqual(SessionCopy.keyEntry(String(compact.prefix(31))), .partial(digits: 31))
        XCTAssertEqual(SessionCopy.keyEntry(compact + "0"), .tooLong(digits: 33))
        XCTAssertEqual(SessionCopy.keyEntry(String(compact.prefix(31)) + "G"), .invalidCharacters)
        XCTAssertEqual(SessionCopy.keyEntry(display.replacingOccurrences(of: "-", with: "—")), .invalidCharacters,
                       "Only the plain dash is ignored, as the parser ignores it.")

        // Every form in between: the hint calls a key complete exactly when the parser accepts it.
        var generator = SeededGenerator(seed: 0x5EED)
        let alphabet = Array("0123456789abcdefABCDEF- \tgZ:—é")
        for trial in 0..<500 {
            let length = Int(generator.next() % 40)
            let text = String((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
            XCTAssertEqual(SessionCopy.keyEntry(text) == .complete, PairingKey(string: text) != nil, "trial \(trial)")
        }
    }

    /// The hint says what is missing using counts only, so it never repeats any part of a key.
    func testTheKeyHintSaysWhatIsMissingWithoutRepeatingTheKey() {
        XCTAssertEqual(SessionCopy.keyEntryHint(.empty),
                       "The 32-character key shown in VisionDesk on your Mac. Dashes and spaces are optional.")
        XCTAssertEqual(SessionCopy.keyEntryHint(.partial(digits: 17)), "17 of 32 characters.")
        XCTAssertEqual(SessionCopy.keyEntryHint(.tooLong(digits: 33)), "33 characters. A pairing key has 32.")
        XCTAssertEqual(SessionCopy.keyEntryHint(.invalidCharacters),
                       "A pairing key uses only the numbers 0–9 and the letters A–F.")
        XCTAssertEqual(SessionCopy.keyEntryHint(SessionCopy.keyEntry(PairingKey.generate().displayValue)),
                       "Pairing key complete.")
    }

    // MARK: Why it did not work

    /// Every reason DeskTransport gives becomes what it means here; an unknown one is kept.
    func testTransportReasonsReadAsWhatHappened() {
        let expected: [String: String] = [
            "Pairing timed out. Check the key and local network.": "Pairing didn't finish in time.",
            "Secure pairing failed. Check the pairing key and local network.": "The secure connection couldn't be set up.",
            "The connection did not negotiate the required security.": "The secure connection couldn't be set up.",
            "The secure connection was interrupted.": "The connection was interrupted.",
            "Truncated frame.": "The connection was interrupted.",
            "The other device disconnected.": "Your Mac closed the connection.",
            "The other device stopped responding. Reconnect and try again.": "Your Mac stopped responding.",
            "The connection is too slow for control. Reconnect and try again.":
                "The connection became too slow to control your Mac safely.",
            "Invalid message length.": "Your Mac sent something this version of VisionDesk can't read.",
            "Invalid message.": "Your Mac sent something this version of VisionDesk can't read.",
            "The connection entered an unsupported state.": "The connection failed unexpectedly."
        ]
        for (reason, plain) in expected {
            XCTAssertEqual(SessionCopy.plainReason(reason), plain)
        }
        XCTAssertEqual(SessionCopy.plainReason("Studio stopped responding."), "Studio stopped responding.")
    }

    /// A nearby Mac's session is never dialled again, so its end says how to start a new one.
    func testALostNearbySessionSaysHowToConnectAgain() {
        XCTAssertEqual(
            SessionCopy.connectionEnded(with: "Studio", reason: "The other device disconnected."),
            "Lost the connection to Studio. Your Mac closed the connection. To connect again, start sharing on your Mac if it stopped, then enter the pairing key it shows."
        )
        XCTAssertTrue(SessionCopy.connectionEnded(with: "", reason: "R.").hasPrefix("Lost the connection to your Mac. R. "))
    }

    // MARK: Finding a Mac

    /// Every status the browser publishes, read from the browser itself, so a reworded status fails
    /// here instead of reaching the wearer as an unexplained problem. Searching, and a search that
    /// restarts by itself, need nothing from the wearer; only the rest offer Search Again.
    @MainActor
    func testAnEmptyNearbyListSaysWhatToDo() {
        for searching in [DeskBrowser.searchingStatus, DeskBrowser.stoppedStatus, "Looking for nearby Macs…"] {
            let guidance = SessionCopy.discoveryGuidance(status: searching)
            XCTAssertEqual(guidance.title, "Looking for your Mac")
            XCTAssertFalse(guidance.needsAttention)
            XCTAssertTrue(guidance.detail.hasPrefix("Start sharing in VisionDesk on your Mac"), guidance.detail)
        }
        let restarting = SessionCopy.discoveryGuidance(status: DeskBrowser.restartingStatus)
        XCTAssertEqual(restarting.title, "Looking for your Mac")
        XCTAssertFalse(restarting.needsAttention, "A search that restarts by itself asks nothing of the wearer.")
        let permission = SessionCopy.discoveryGuidance(status: DeskBrowser.waitingStatus)
        XCTAssertEqual(permission.title, "Allow Local Network access")
        XCTAssertTrue(permission.needsAttention)
        XCTAssertTrue(permission.detail.contains("Settings under Privacy & Security"), permission.detail)
        let failed = SessionCopy.discoveryGuidance(status: DeskBrowser.failedStatus)
        XCTAssertEqual(failed.title, "Couldn't search this network")
        XCTAssertTrue(failed.needsAttention)
        let unknown = SessionCopy.discoveryGuidance(status: DeskBrowser.unsupportedStatus)
        XCTAssertTrue(unknown.needsAttention)
        XCTAssertEqual(unknown.detail, DeskBrowser.unsupportedStatus, "An unlisted status is shown as it is.")
    }

    // MARK: One vocabulary

    /// The Mac calls it a pairing key, so the headset does too, and nothing says "other device".
    func testThePairingWordsMatchTheMac() {
        let reasons = ["Pairing timed out. Check the key and local network.", "The other device disconnected."]
        var sentences = [SessionCopy.incompleteKeyMessage,
                         SessionCopy.gaveUp(on: "Studio", everConnected: false),
                         SessionCopy.gaveUp(on: "Studio", everConnected: true)]
        for reason in reasons {
            sentences.append(SessionCopy.couldNotConnect(to: "Studio", reason: reason, route: .nearby))
            sentences.append(SessionCopy.couldNotConnect(to: "Studio", reason: reason, route: .address))
            sentences.append(SessionCopy.connectionEnded(with: "Studio", reason: reason))
        }
        sentences += [SessionCopy.KeyEntry.empty, .partial(digits: 3), .tooLong(digits: 40), .invalidCharacters, .complete]
            .map(SessionCopy.keyEntryHint)
        for sentence in sentences {
            XCTAssertFalse(sentence.lowercased().contains("pairing code"), sentence)
            XCTAssertFalse(sentence.contains("other device"), sentence)
            XCTAssertFalse(sentence.contains("Check the key"), sentence)
        }
    }
}

/// A small deterministic generator, so a failing trial can be found again by its number.
private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
}
