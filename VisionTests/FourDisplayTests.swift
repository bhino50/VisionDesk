import DeskCore
import Foundation
import XCTest
@testable import VisionDesk

/// Exercises four real protocol streams and source-bound input through the production client.
@MainActor
final class FourDisplayTests: XCTestCase {
    func testFourDistinctFramesRouteInputAndRemovalPreservesRemainingStreams() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        let sizes = [CGSize(width: 48, height: 30), CGSize(width: 64, height: 36),
                     CGSize(width: 27, height: 48), CGSize(width: 36, height: 64)]
        let ids: [UInt32] = [1, 3, 4, 5]
        let infos = ids.enumerated().map { index, id in
            DisplayInfo(id: id, name: index == 0 ? "Built-in" : "External \(id)",
                        width: Int(sizes[index].width) * 40, height: Int(sizes[index].height) * 40,
                        originX: Double(index) * 1920, originY: 0,
                        pointWidth: Double(sizes[index].width) * 20,
                        pointHeight: Double(sizes[index].height) * 20)
        }
        XCTAssertTrue(mac.publish(displays: infos))
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { model.displays.count == 4 && model.isMacControlEnabled }
        for (index, id) in ids.enumerated() {
            let frame = try XCTUnwrap(DeskFixtures.jpeg(width: Int(sizes[index].width),
                                                      height: Int(sizes[index].height)))
            XCTAssertTrue(mac.sendFrame(frame, displayID: id))
        }
        try await Loopback.waitUntil { ids.allSatisfy { model.canControl(displayID: $0) } }
        let streams = try ids.map { try XCTUnwrap(model.display(id: $0)) }
        for (index, stream) in streams.enumerated() {
            XCTAssertEqual(stream.image?.size, sizes[index], "Each source must decode its own pixel grid.")
            let point = CGPoint(x: 0.2 + Double(index) * 0.1, y: 0.7 - Double(index) * 0.1)
            let previous = mac.received.filter { $0.kind == "input" }.count
            model.placePointer(displayID: stream.id, at: point)
            model.clickAtLastPointer(displayID: stream.id)
            try await Loopback.waitUntil { mac.received.filter { $0.kind == "input" }.count >= previous + 4 }
            let inputs = Array(mac.received.filter { $0.kind == "input" }.dropFirst(previous))
            XCTAssertEqual(inputs.compactMap(\.action), ["move", "move", "leftDown", "leftUp"])
            for message in inputs {
                XCTAssertEqual(message.displayID, stream.id)
                XCTAssertEqual(try XCTUnwrap(message.x), point.x, accuracy: 1e-9)
                XCTAssertEqual(try XCTUnwrap(message.y), point.y, accuracy: 1e-9)
            }
        }

        XCTAssertTrue(mac.publish(displays: Array(infos.dropLast())))
        try await Loopback.waitUntil { model.displays.count == 3 }
        XCTAssertNil(streams[3].image)
        XCTAssertFalse(model.canControl(displayID: 5))
        let previous = mac.actions.count
        model.placePointer(displayID: 5, at: CGPoint(x: 0.4, y: 0.5))
        model.clickAtLastPointer(displayID: 5)
        model.tapClick(displayID: 5, at: CGPoint(x: 0.4, y: 0.5))
        try await Loopback.pause(0.3)
        XCTAssertEqual(mac.actions.count, previous, "A removed source cannot send stale input.")
        for (index, id) in ids.dropLast().enumerated() {
            XCTAssertTrue(model.display(id: id) === streams[index], "Hotplug preserves unaffected window streams.")
            XCTAssertEqual(streams[index].image?.size, sizes[index])
            XCTAssertTrue(model.canControl(displayID: id))
        }
        let updated = try XCTUnwrap(DeskFixtures.jpeg(width: 32, height: 18))
        XCTAssertTrue(mac.sendFrame(updated, displayID: 3))
        try await Loopback.waitUntil { streams[1].image?.size == CGSize(width: 32, height: 18) }
        XCTAssertEqual(streams[0].image?.size, sizes[0])
        XCTAssertEqual(streams[2].image?.size, sizes[2])
    }
}
