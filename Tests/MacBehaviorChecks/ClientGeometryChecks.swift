import CoreGraphics
import Foundation

/// The visionOS client's aspect-fit mapping, compiled from the real
/// `VisionApp/Services/DisplayGeometry.swift`. It depends only on CoreGraphics, so the Mac
/// harness can exercise the same code the headset runs.
@MainActor
func runClientGeometryChecks(_ runner: CheckRunner) async {
    let container = CGSize(width: 1_000, height: 1_000)
    let image = CGSize(width: 1_920, height: 1_080)

    await runner.check("An aspect-fit screen is centred inside its window") {
        guard let rect = DisplayGeometry.imageRect(in: container, image: image) else {
            runner.expect(false, "a valid container and image must produce a rect")
            return
        }
        runner.expectClose(Double(rect.width), 1_000, "fitted width")
        runner.expectClose(Double(rect.height), 562.5, "fitted height")
        runner.expectClose(Double(rect.minX), 0, "no horizontal letterbox at this ratio")
        runner.expectClose(Double(rect.minY), 218.75, "vertical letterbox is split evenly")

        // A window narrower than the screen letterboxes by a different amount.
        guard let tall = DisplayGeometry.imageRect(in: CGSize(width: 400, height: 1_000), image: image) else {
            runner.expect(false, "a tall container must produce a rect")
            return
        }
        runner.expectClose(Double(tall.width), 400, "fitted width in a tall window")
        runner.expectClose(Double(tall.height), 225, "fitted height in a tall window")
        runner.expectClose(Double(tall.minX), 0, "no horizontal letterbox in a tall window")
        runner.expectClose(Double(tall.minY), 387.5, "vertical letterbox in a tall window")
    }

    await runner.check("Normalized coordinates come from the image, never the letterbox") {
        guard let rect = DisplayGeometry.imageRect(in: container, image: image) else {
            runner.expect(false, "a valid container and image must produce a rect")
            return
        }
        guard let topLeft = DisplayGeometry.normalized(CGPoint(x: rect.minX, y: rect.minY), in: container, image: image),
              let bottomRight = DisplayGeometry.normalized(
                CGPoint(x: rect.maxX, y: rect.maxY), in: container, image: image
              ),
              let centre = DisplayGeometry.normalized(CGPoint(x: rect.midX, y: rect.midY), in: container, image: image)
        else {
            runner.expect(false, "the image's own corners must normalize")
            return
        }
        runner.expectClose(Double(topLeft.x), 0, "top-left x")
        runner.expectClose(Double(topLeft.y), 0, "top-left y")
        runner.expectClose(Double(bottomRight.x), 1, "bottom-right x")
        runner.expectClose(Double(bottomRight.y), 1, "bottom-right y")
        runner.expectClose(Double(centre.x), 0.5, "centre x")
        runner.expectClose(Double(centre.y), 0.5, "centre y")
    }

    await runner.check("A tap in the letterbox is rejected but a drag out of it clamps") {
        guard let rect = DisplayGeometry.imageRect(in: container, image: image) else {
            runner.expect(false, "a valid container and image must produce a rect")
            return
        }
        let above = CGPoint(x: rect.midX, y: rect.minY - 20)
        let below = CGPoint(x: rect.midX, y: rect.maxY + 20)

        runner.expect(
            DisplayGeometry.normalized(above, in: container, image: image) == nil,
            "a tap above the screen must not become a pointer position"
        )
        runner.expect(
            DisplayGeometry.normalized(below, in: container, image: image) == nil,
            "a tap below the screen must not become a pointer position"
        )

        // A drag that leaves the image must clamp to the edge instead of dropping events,
        // so a held mouse button keeps tracking rather than stalling mid-drag.
        guard let clampedAbove = DisplayGeometry.normalized(above, in: container, image: image, clampToImage: true),
              let clampedBelow = DisplayGeometry.normalized(below, in: container, image: image, clampToImage: true)
        else {
            runner.expect(false, "a clamped drag must still produce a position")
            return
        }
        runner.expectClose(Double(clampedAbove.y), 0, "a drag above the screen clamps to the top edge")
        runner.expectClose(Double(clampedBelow.y), 1, "a drag below the screen clamps to the bottom edge")
        runner.expect(
            (0...1).contains(clampedAbove.x) && (0...1).contains(clampedBelow.x),
            "clamped coordinates must stay normalized"
        )
    }

    await runner.check("Degenerate geometry produces no pointer position") {
        runner.expect(
            DisplayGeometry.imageRect(in: .zero, image: image) == nil,
            "a zero-sized window must not produce a rect"
        )
        runner.expect(
            DisplayGeometry.imageRect(in: container, image: .zero) == nil,
            "a zero-sized image must not produce a rect"
        )
        // Spell out CGFloat: a bare `.nan` is ambiguous between CGFloat and Double here.
        runner.expect(
            DisplayGeometry.imageRect(in: CGSize(width: CGFloat.nan, height: 100), image: image) == nil,
            "a non-finite window must not produce a rect"
        )
        runner.expect(
            DisplayGeometry.imageRect(in: container, image: CGSize(width: 100, height: CGFloat.infinity)) == nil,
            "a non-finite image must not produce a rect"
        )
        runner.expect(
            DisplayGeometry.normalized(CGPoint(x: CGFloat.infinity, y: 0), in: container, image: image) == nil,
            "a non-finite location must not normalize"
        )
        runner.expect(
            DisplayGeometry.normalized(
                CGPoint(x: 0, y: CGFloat.nan), in: container, image: image, clampToImage: true
            ) == nil,
            "a non-finite location must not normalize even when clamping"
        )
    }

    await runner.check("Normalized coordinates round-trip back to the same window point") {
        guard let rect = DisplayGeometry.imageRect(in: container, image: image) else {
            runner.expect(false, "a valid container and image must produce a rect")
            return
        }
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let location = CGPoint(
                x: rect.minX + rect.width * CGFloat(fraction),
                y: rect.minY + rect.height * CGFloat(fraction)
            )
            guard let normalized = DisplayGeometry.normalized(location, in: container, image: image) else {
                runner.expect(false, "fraction \(fraction) must normalize")
                continue
            }
            runner.expectClose(Double(normalized.x), fraction, "round-trip x at \(fraction)", tolerance: 0.000_1)
            runner.expectClose(Double(normalized.y), fraction, "round-trip y at \(fraction)", tolerance: 0.000_1)
        }
    }
}
