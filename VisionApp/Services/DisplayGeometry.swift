import CoreGraphics

/// Screen coordinates are relative to the visible image, never the letterbox.
enum DisplayGeometry {
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
