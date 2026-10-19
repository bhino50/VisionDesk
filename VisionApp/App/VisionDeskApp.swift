import SwiftUI

@main
struct VisionDeskApp: App {
    @StateObject private var session = DeskClientModel()

    var body: some Scene {
        WindowGroup("VisionDesk", id: "desk") {
            WorkspaceWindow(model: session)
        }
        .defaultSize(width: 820, height: 720)
        .windowResizability(.contentMinSize)

        WindowGroup("Mac Display", id: "display", for: UInt32.self) { $displayID in
            DisplayWindow(model: session, displayID: displayID ?? 0)
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentMinSize)
        .defaultWindowPlacement { _, context in
            // Give Open All distinct initial positions around the overview. visionOS
            // still owns final placement, and the person can move/resize each screen.
            guard let overview = context.windows.first(where: { $0.id == "desk" }) else {
                return WindowPlacement()
            }
            let screenCount = context.windows.filter { $0.id == "display" }.count
            switch screenCount % 4 {
            case 0: return WindowPlacement(.trailing(overview))
            case 1: return WindowPlacement(.leading(overview))
            case 2: return WindowPlacement(.above(overview))
            default: return WindowPlacement(.below(overview))
            }
        }
    }
}
