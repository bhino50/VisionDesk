import SwiftUI
import UIKit

/// Requests geometry only for the scene hosting this anchor, and only when its display aspect
/// changes. SwiftUI frame updates and user resizing do not keep resetting the window size.
@MainActor
struct DisplayWindowGeometry: UIViewRepresentable {
    let imageSize: CGSize
    let onFailure: (String?) -> Void

    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {
        view.imageSize = imageSize
        view.onFailure = onFailure
        view.applyIfNeeded()
    }

    final class Anchor: UIView {
        var imageSize = CGSize.zero
        var onFailure: (String?) -> Void = { _ in }
        private weak var requestedScene: UIWindowScene?
        private var requestedAspect: CGFloat?
        private var requestGeneration: UInt64 = 0
        private var failedGeneration: UInt64?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                // Invalidate callbacks from a scene this anchor no longer belongs to.
                requestGeneration &+= 1
                requestedScene = nil
                requestedAspect = nil
                return
            }
            applyIfNeeded()
        }

        func applyIfNeeded() {
            guard let scene = window?.windowScene,
                  let sizing = DisplayGeometry.windowSizing(image: imageSize) else { return }
            let aspect = imageSize.width / imageSize.height
            guard requestedScene !== scene || requestedAspect.map({ abs($0 - aspect) > 0.0001 }) != false else { return }
            requestedScene = scene
            requestedAspect = aspect
            requestGeneration &+= 1
            let generation = requestGeneration
            failedGeneration = nil
            // Publish outside UIViewRepresentable's update, which can occur during a
            // SwiftUI render. An older clear must not erase this request's failure.
            Task { @MainActor [weak self, weak scene] in
                guard let self, let scene, self.requestGeneration == generation,
                      self.requestedScene === scene, self.window?.windowScene === scene,
                      self.failedGeneration != generation else { return }
                self.onFailure(nil)
            }
            let preferences = UIWindowScene.GeometryPreferences.Vision(
                size: sizing.preferred, minimumSize: sizing.minimum, resizingRestrictions: .uniform
            )
            scene.requestGeometryUpdate(preferences) { [weak self, weak scene] _ in
                // No retry loop: leave the current usable window and explain the fallback.
                Task { @MainActor [weak self, weak scene] in
                    guard let self, let scene, self.requestGeneration == generation,
                          self.requestedScene === scene, self.window?.windowScene === scene else { return }
                    self.failedGeneration = generation
                    self.onFailure("The screen size could not adjust automatically. Resize the window using a lower corner.")
                }
            }
        }
    }
}
