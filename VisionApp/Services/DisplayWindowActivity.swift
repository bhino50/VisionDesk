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

    static func open(displayID: UInt32, onFailure: @escaping () -> Void) {
        guard displayID > 0 else { onFailure(); return }
        var request = UISceneSessionActivationRequest()
        request.userActivity = make(displayID: displayID)
        UIApplication.shared.activateSceneSession(for: request) { _ in onFailure() }
    }
}
