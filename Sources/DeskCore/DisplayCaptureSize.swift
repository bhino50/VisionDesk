import Foundation

/// Fits capture output inside both receiver allocation budgets before native resources exist.
/// The source aspect remains intact within integer rounding; Mac input uses its original geometry.
/// H.264 also caps coded edges at 4,096 pixels as a conservative native encoder budget. This
/// avoids observed long-edge failures, but does not certify support on every hardware encoder.
public struct DisplayCaptureSize: Equatable, Sendable {
    public enum Format: CaseIterable, Sendable { case h264, jpeg }
    public enum Failure: Error, Equatable, LocalizedError {
        case invalidSourceGeometry
        case unrepresentableAspectRatio

        public var errorDescription: String? {
            switch self {
            case .invalidSourceGeometry: return "The display reported invalid capture dimensions."
            case .unrepresentableAspectRatio: return "The display's aspect ratio cannot fit the supported capture dimensions."
            }
        }
    }

    public static let maximumWidth = 1_920
    public let width: Int
    public let height: Int

    public init(pixelWidth: Int, aspectWidth: Int, aspectHeight: Int, format: Format) throws {
        guard pixelWidth > 0, aspectWidth > 0, aspectHeight > 0 else {
            throw Failure.invalidSourceGeometry
        }
        let quantum = format == .h264 ? 2 : 1
        let minimum = format == .h264 ? EncodedVideoFrame.minimumDimension : 1
        let block = format == .h264 ? 16 : 1
        let maximumDimension = format == .h264 ? min(4096, EncodedVideoFrame.maximumDimension)
                                              : EncodedVideoFrame.maximumDimension
        // At most 1,920 candidates, independent of the source's magnitude. Descending integer
        // widths retain the old size whenever it fits, including the existing odd-edge rounding.
        for proposedWidth in stride(from: min(Self.maximumWidth, pixelWidth), through: minimum, by: -1) {
            let proposedHeight = Double(proposedWidth) * Double(aspectHeight) / Double(aspectWidth)
            // Bound the floating-point value before converting to Int. Rounding removes less
            // than quantum pixels; neither extreme ratios nor padding may overflow.
            guard proposedHeight.isFinite,
                  proposedHeight < Double(maximumDimension + quantum) else { continue }
            let width = proposedWidth - proposedWidth % quantum
            let truncatedHeight = Int(proposedHeight)
            let height = truncatedHeight - truncatedHeight % quantum
            guard width >= minimum, height >= minimum else { break }
            // H.264 allocates complete 16×16 macroblocks even when its visible crop fits.
            // JPEG-only capture has no coded padding, but shares the decoded-pixel budget.
            let codedWidth = (width + block - 1) / block * block
            let codedHeight = (height + block - 1) / block * block
            guard codedWidth <= maximumDimension,
                  codedHeight <= maximumDimension,
                  codedWidth <= EncodedVideoFrame.maximumPixels / codedHeight else { continue }
            self.width = width
            self.height = height
            return
        }
        // Upscaling or stretching a tiny edge would hide an unsupported aspect ratio.
        throw Failure.unrepresentableAspectRatio
    }
}
