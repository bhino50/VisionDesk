import CoreGraphics

/// Screen coordinates are relative to the visible image, never the letterbox.
enum DisplayGeometry {
    /// Preview cards use the source's shape too, so portrait targets are not letterboxed
    /// into a landscape hit area before the wearer opens their window.
    static func previewAspectRatio(image: CGSize) -> CGFloat {
        guard image.width.isFinite, image.height.isFinite,
              image.width > 0, image.height > 0 else { return 16 / 10 }
        let ratio = image.width / image.height
        return ratio.isFinite && ratio > 0 ? ratio : 16 / 10
    }

    struct WindowSizing: Equatable {
        let preferred: CGSize
        let minimum: CGSize
    }

    /// Keep the desktop's aspect without stretching or cropping. Chrome lives in ornaments,
    /// so these dimensions describe the picture alone, including portrait and ultrawide Macs.
    static func windowSizing(image: CGSize) -> WindowSizing? {
        guard image.width.isFinite, image.height.isFinite,
              image.width > 0, image.height > 0 else { return nil }
        let scale = min(1120 / image.width, 1000 / image.height)
        let preferred = CGSize(width: image.width * scale, height: image.height * scale)
        guard preferred.width.isFinite, preferred.height.isFinite,
              preferred.width > 0, preferred.height > 0 else { return nil }
        let minimumScale = min(1, max(320 / preferred.width, 180 / preferred.height))
        return WindowSizing(preferred: preferred,
                            minimum: CGSize(width: preferred.width * minimumScale,
                                            height: preferred.height * minimumScale))
    }

    static func imageRect(in container: CGSize, image: CGSize) -> CGRect? {
        guard container.width.isFinite, container.height.isFinite,
              image.width.isFinite, image.height.isFinite,
              container.width > 0, container.height > 0,
              image.width > 0, image.height > 0 else { return nil }
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func normalized(
        _ location: CGPoint,
        in container: CGSize,
        image: CGSize,
        clampToImage: Bool = false
    ) -> CGPoint? {
        guard location.x.isFinite, location.y.isFinite,
              let rect = imageRect(in: container, image: image) else { return nil }
        if !clampToImage {
            guard location.x >= rect.minX, location.x <= rect.maxX,
                  location.y >= rect.minY, location.y <= rect.maxY else { return nil }
        }
        return CGPoint(
            x: min(1, max(0, (location.x - rect.minX) / rect.width)),
            y: min(1, max(0, (location.y - rect.minY) / rect.height))
        )
    }
}
