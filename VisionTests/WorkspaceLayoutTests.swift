import SwiftUI
import DeskTransport
import UIKit
import XCTest
@testable import VisionDesk

@MainActor
final class WorkspaceLayoutTests: XCTestCase {
    func testDisconnectedMinimumWindowDoesNotNestScrolling() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let model = DeskClientModel(
            keys: Loopback.store(MemoryKeychain()),
            preferences: MemoryRememberedMacStore())
        let controller = UIHostingController(rootView:
            WorkspaceWindow(model: model).environmentObject(DeskWindowRegistry())
                .frame(width: 720, height: 600))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 720, height: 600)
        window.rootViewController = controller
        defer {
            model.disconnect()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // Hosting commits after the initial SwiftUI transaction.
        for _ in 0..<10 {
            await Task.yield()
            controller.view.layoutIfNeeded()
        }
        let scrollViews = descendants(controller.view).compactMap { $0 as? UIScrollView }
        XCTAssertFalse(scrollViews.isEmpty, "The actual pairing content must render its scroll view.")
        for scroll in scrollViews {
            var ancestor = scroll.superview
            while let current = ancestor {
                XCTAssertFalse(current is UIScrollView,
                               "An outer scroll view scrolls the panel's Connect/status row away.")
                ancestor = current.superview
            }
        }
        // This verifies UIKit scroll containment, not rendered button visibility.
        // visionOS offscreen drawHierarchy captures are blank on the QA runtime.
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

}
