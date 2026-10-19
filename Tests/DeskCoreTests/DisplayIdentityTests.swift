import DeskCore
import XCTest

final class DisplayIdentityTests: XCTestCase {
    func testFourPhysicalScreensHaveDistinctSourceLabels() {
        let builtin = DisplayIdentity.name(localizedName: "Color LCD", displayID: 1, builtIn: true,
                                           main: true, width: 3456, height: 2234)
        let landscape = DisplayIdentity.name(localizedName: "SAMSUNG", displayID: 3, builtIn: false,
                                             main: false, width: 3840, height: 2160)
        let dell = DisplayIdentity.name(localizedName: "DELL", displayID: 4, builtIn: false,
                                       main: false, width: 1440, height: 2560)
        let portrait = DisplayIdentity.name(localizedName: "SAMSUNG", displayID: 5, builtIn: false,
                                            main: false, width: 2160, height: 3840)
        XCTAssertEqual(Set([builtin, landscape, dell, portrait]).count, 4)
        XCTAssertEqual(builtin, "Built-in · Color LCD · Landscape, Main · ID 1")
        XCTAssertEqual(landscape, "External · SAMSUNG · Landscape · ID 3")
        XCTAssertEqual(portrait, "External · SAMSUNG · Portrait · ID 5")
        XCTAssertTrue(dell.contains("Portrait"))
    }

    func testIdenticalModelsAndOrientationsRemainDistinct() {
        let labels = [UInt32(3), 5].map {
            DisplayIdentity.name(localizedName: "SAMSUNG", displayID: $0, builtIn: false,
                                 main: false, width: 1920, height: 1080)
        }
        XCTAssertNotEqual(labels[0], labels[1])
        XCTAssertEqual(DisplayIdentity.name(localizedName: "SAMSUNG", displayID: 3, builtIn: false,
                                             main: false, width: 1920, height: 1080), labels[0])
    }

    func testEmptyModelFallsBackAndExternalCanBeMain() {
        XCTAssertEqual(DisplayIdentity.name(localizedName: " \n", displayID: 9, builtIn: false,
                                             main: true, width: 1080, height: 1920),
                       "External · Display · Portrait, Main · ID 9")
    }
}
