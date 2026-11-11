import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit

public enum StageScreenshotError: Error, Equatable {
    case invalidOutputSize
    case unableToCreateImageDestination
    case unableToWritePNG
    case unableToCreateCapturedImage
    case unableToCreatePaddedImage
}

/// Captures a display crop that frames a target app window with transparency around it.
public enum StageScreenshot {
    public static let fullHDSize = CGSize(width: 1_920, height: 1_080)

    public static func capture(
        window: StageCaptureWindow,
        display: StageCaptureDisplay,
        framing: StageCaptureFraming,
        outputSize: CGSize = fullHDSize,
        includesWindowShadow: Bool = false,
        includingWindows: [StageCaptureWindow] = []
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
        let filter = try await StageCaptureDiscovery.displayFilter(
            display: display,
            including: window,
            additionalWindows: includingWindows
        )
        let configuration = SCScreenshotConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.destinationRect = destinationRect
        configuration.showsCursor = false
        configuration.ignoreShadows = !includesWindowShadow
        let screenshot = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter,
            configuration: configuration
        )
        guard let image = screenshot.sdrImage else { throw StageScreenshotError.unableToCreateCapturedImage }
        return image
    }

    public static func captureNativeWindow(
        window: StageCaptureWindow,
        includesWindowShadow: Bool
    ) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window.screenCaptureWindow)
        let configuration = SCScreenshotConfiguration()
        configuration.ignoreShadows = !includesWindowShadow
        configuration.showsCursor = false
        let screenshot = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter,
            configuration: configuration
        )
        guard let image = screenshot.sdrImage else { throw StageScreenshotError.unableToCreateCapturedImage }
        return image
    }

    public static func addingTransparentPadding(
        around image: CGImage,
        horizontalMargin: CGFloat,
        verticalMargin: CGFloat,
        scale: CGFloat
    ) throws -> CGImage {
        guard horizontalMargin.isFinite, verticalMargin.isFinite,
              horizontalMargin >= 0, verticalMargin >= 0,
              scale.isFinite, scale > 0 else {
            throw StageCaptureGeometryError.invalidMargins
        }
        let horizontalPixelMargin = (horizontalMargin * scale).rounded(.up)
        let verticalPixelMargin = (verticalMargin * scale).rounded(.up)
        guard horizontalPixelMargin.isFinite, verticalPixelMargin.isFinite,
              horizontalPixelMargin < CGFloat((Int.max - image.width) / 2),
              verticalPixelMargin < CGFloat((Int.max - image.height) / 2) else {
            throw StageScreenshotError.invalidOutputSize
        }
        let horizontalPixels = Int(horizontalPixelMargin)
        let verticalPixels = Int(verticalPixelMargin)
        guard horizontalPixels > 0 || verticalPixels > 0 else { return image }
        let width = image.width + horizontalPixels * 2
        let height = image.height + verticalPixels * 2
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw StageScreenshotError.unableToCreatePaddedImage
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(
            image,
            in: CGRect(x: horizontalPixels, y: verticalPixels, width: image.width, height: image.height)
        )
        guard let paddedImage = context.makeImage() else {
            throw StageScreenshotError.unableToCreatePaddedImage
        }
        return paddedImage
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
