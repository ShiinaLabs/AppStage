import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit

public enum StageScreenshotError: Error, Equatable {
    case invalidOutputSize
    case unableToCreateImageDestination
    case unableToWritePNG
}

/// Captures a display crop that frames a target app window with desktop around it.
public enum StageScreenshot {
    public static let fullHDSize = CGSize(width: 1_920, height: 1_080)
    private static let backgroundColor = CGColor(gray: 0, alpha: 1)

    public static func capture(
        window: StageCaptureWindow,
        display: StageCaptureDisplay,
        framing: StageCaptureFraming,
        outputSize: CGSize = fullHDSize
    ) async throws -> CGImage {
        guard outputSize.width.isFinite, outputSize.height.isFinite,
              outputSize.width > 0, outputSize.height > 0,
              outputSize.width.rounded(.towardZero) == outputSize.width,
              outputSize.height.rounded(.towardZero) == outputSize.height,
              outputSize.width < CGFloat(Int.max), outputSize.height < CGFloat(Int.max)
        else {
            throw StageScreenshotError.invalidOutputSize
        }

        let sourceRect = try StageCaptureGeometry.captureRect(
            windowFrame: window.frame,
            displayFrame: display.frame,
            framing: framing
        )
        let destinationRect = try StageCaptureGeometry.aspectFitRect(
            sourceSize: sourceRect.size,
            outputSize: outputSize
        )
        let filter = try await StageCaptureDiscovery.displayFilter(display: display, including: window)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.destinationRect = destinationRect
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.backgroundColor = backgroundColor

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    public static func writePNG(_ image: CGImage, to outputURL: URL) throws {
        let directoryURL = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw StageScreenshotError.unableToCreateImageDestination
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StageScreenshotError.unableToWritePNG
        }
    }
}
