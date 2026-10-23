import Foundation
import UIKit

/// Native drag-to-space and button requests share the same navigation route. This activity
/// carries only a display number: it never carries a frame, address, key, or control grant.
@MainActor
enum DisplayWindowActivity {
    static let activityType = "org.visiondesk.open-display"
    static let targetPrefix = "visiondesk-display:"

    static func target(for id: UInt32) -> String { "\(targetPrefix)\(id):" }

    static func make(displayID: UInt32) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.targetContentIdentifier = target(for: displayID)
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        return activity
    }

    static func displayID(from activity: NSUserActivity) -> UInt32? {
        guard activity.activityType == activityType,
              let target = activity.targetContentIdentifier,
              target.hasPrefix(targetPrefix), target.hasSuffix(":"),
              let id = UInt32(target.dropFirst(targetPrefix.count).dropLast()), id > 0,
              target == self.target(for: id) else { return nil }
        return id
    }

    static func itemProvider(displayID: UInt32) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerObject(make(displayID: displayID), visibility: .all)
        return provider
    }

    /// Every in-app screen action uses the same native route as drag-to-space. The registry
    /// reserves creation and restores its button on failure; an existing window is activated.
    static func open(displayID: UInt32, registry: DeskWindowRegistry,
                     request: ((UInt32, @escaping () -> Void) -> Void)? = nil) {
        let key = DeskWindowRegistry.Key.display(displayID)
        registry.open(key) {
            guard let token = registry.openingToken(for: key) else { return }
            let failed: () -> Void = { [weak registry] in
                registry?.creationFailed(key, token: token)
            }
            if let request { request(displayID, failed) }
            else { open(displayID: displayID, onFailure: failed) }
        }
    }

    static func open(displayID: UInt32, onFailure: @escaping () -> Void) {
        guard displayID > 0 else { onFailure(); return }
        // An untargeted request can create another scene even after this display's anchor
        // has registered. Select the known native session explicitly instead of relying on
        // SwiftUI's external-event preferences to have reached UIKit already.
        var request = registeredSession(displayID: displayID)
            .map { UISceneSessionActivationRequest(session: $0) } ?? UISceneSessionActivationRequest()
        request.userActivity = make(displayID: displayID)
        UIApplication.shared.activateSceneSession(for: request) { _ in onFailure() }
    }

    private static func registeredSession(displayID: UInt32) -> UISceneSession? {
        let key = DeskWindowRegistry.Key.display(displayID)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            if scene.windows.contains(where: {
                containsRegisteredDisplay(in: $0, key: key, sessionID: scene.session.persistentIdentifier)
            }) {
                return scene.session
            }
        }
        return nil
    }

    private static func containsRegisteredDisplay(in view: UIView, key: DeskWindowRegistry.Key,
                                                  sessionID: String) -> Bool {
        if let anchor = view as? DeskWindowAnchor.Anchor,
           anchor.boundKey == key,
           let entry = anchor.boundRegistry?.entries[key],
           entry.owner == anchor.owner, entry.sessionID == sessionID {
            return true
        }
        return view.subviews.contains {
            containsRegisteredDisplay(in: $0, key: key, sessionID: sessionID)
        }
    }
}
