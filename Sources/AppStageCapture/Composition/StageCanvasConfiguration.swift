import CoreGraphics
import Foundation
import ImageIO

public enum StageCanvasConfigurationError: Error, Equatable, LocalizedError {
    case backgroundImageNotFound
    case backgroundImageCouldNotBeDecoded
    case dimensionsMustBeEven

    public var errorDescription: String? {
        switch self {
        case .backgroundImageNotFound:
            "Background image file does not exist."
        case .backgroundImageCouldNotBeDecoded:
            "Background image could not be decoded."
        case .dimensionsMustBeEven:
            "Background image dimensions must be even."
        }
    }
}

/// A fixed raster background that also defines the final video canvas size.
public struct StageCanvasConfiguration: Equatable, Sendable {
    public let backgroundImageURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int

    public var resolution: StageCaptureResolution {
        .custom(width: pixelWidth, height: pixelHeight)
    }

    public var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    public init(backgroundImageURL: URL) throws {
        let standardizedURL = backgroundImageURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
            throw StageCanvasConfigurationError.backgroundImageNotFound
        }
        guard let source = CGImageSourceCreateWithURL(standardizedURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else {
            throw StageCanvasConfigurationError.backgroundImageCouldNotBeDecoded
        }
        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw StageCanvasConfigurationError.dimensionsMustBeEven
        }

        self.backgroundImageURL = standardizedURL
        self.pixelWidth = width
        self.pixelHeight = height
    }
}
