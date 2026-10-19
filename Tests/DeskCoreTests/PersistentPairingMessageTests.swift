import DeskCore
import Foundation
import XCTest

final class PersistentPairingMessageTests: XCTestCase {
    func testPersistenceStatusRoundTripsWithoutRequiringOtherStatusFields() throws {
        for retained in [true, false] {
            let message = DeskMessage(kind: "status", keepsPairing: retained)
            XCTAssertTrue(message.isValid)
            XCTAssertEqual(try JSONDecoder().decode(DeskMessage.self, from: JSONEncoder().encode(message)), message)
        }
    }

    func testOlderStatusHasNoPersistencePromise() throws {
        let data = Data(#"{"version":1,"kind":"status","status":"Ready"}"#.utf8)
        let message = try JSONDecoder().decode(DeskMessage.self, from: data)
        XCTAssertTrue(message.isValid)
        XCTAssertNil(message.keepsPairing)
    }

    func testPersistenceFlagCannotBeSmuggledOnOtherKinds() {
        let messages = [
            DeskMessage(kind: "heartbeat"),
            DeskMessage(kind: "stop"),
            DeskMessage(kind: "requestControl"),
            DeskMessage(kind: "displays", displays: []),
            DeskMessage(kind: "capabilities", videoCodec: DeskMessage.supportedVideoCodec)
        ]
        for var message in messages {
            XCTAssertTrue(message.isValid)
            for value in [true, false] {
                message.keepsPairing = value
                XCTAssertFalse(message.isValid, message.kind)
            }
        }
    }
}
