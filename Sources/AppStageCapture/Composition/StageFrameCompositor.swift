import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

enum StageFrameCompositorError: Error, Equatable, LocalizedError {
    case backgroundImageCouldNotBeDecoded
    case sourceFrameUnavailable
    case pixelBufferPoolUnavailable
    case destinationBufferAllocationFailed(OSStatus)
    case frameDimensionsMismatch

    var errorDescription: String? {
        switch self {
        case .backgroundImageCouldNotBeDecoded:
            "Background image could not be decoded."
        case .sourceFrameUnavailable:
            "The captured video frame has no image buffer."
        case .pixelBufferPoolUnavailable:
            "The video writer pixel buffer pool is unavailable."
        case let .destinationBufferAllocationFailed(status):
            "Could not allocate a composited video frame (Core Video status \(status))."
        case .frameDimensionsMismatch:
            "The captured frame dimensions do not match the background canvas."
        }
    }
}

/// Composites a transparent ScreenCaptureKit frame over one fixed background.
final class StageFrameCompositor {
    private let canvas: StageCanvasConfiguration
    private let backgroundImage: CIImage
    private let colorSpace: CGColorSpace
    private let context: CIContext
    private let bounds: CGRect

    init(canvas: StageCanvasConfiguration) throws {
        guard let imageSource = CGImageSourceCreateWithURL(canvas.backgroundImageURL as CFURL, nil),
              let backgroundCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              backgroundCGImage.width == canvas.pixelWidth,
              backgroundCGImage.height == canvas.pixelHeight
        else {
            throw StageFrameCompositorError.backgroundImageCouldNotBeDecoded
        }

        self.canvas = canvas
        self.backgroundImage = CIImage(cgImage: backgroundCGImage)
        let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.colorSpace = sRGBColorSpace
        self.bounds = CGRect(origin: .zero, size: canvas.pixelSize)
        self.context = CIContext(options: [
            .workingColorSpace: sRGBColorSpace,
            .outputColorSpace: sRGBColorSpace,
            .cacheIntermediates: false,
        ])
    }

    func composite(
        source: CVPixelBuffer,
        pixelBufferPool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        guard CVPixelBufferGetWidth(source) == canvas.pixelWidth,
              CVPixelBufferGetHeight(source) == canvas.pixelHeight
        else {
            throw StageFrameCompositorError.frameDimensionsMismatch
        }
        guard let pixelBufferPool else {
            throw StageFrameCompositorError.pixelBufferPoolUnavailable
        }

        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &destination)
        guard status == kCVReturnSuccess, let destination else {
            throw StageFrameCompositorError.destinationBufferAllocationFailed(status)
        }

        let capturedLayer = CIImage(cvPixelBuffer: source)
        let composedFrame = capturedLayer.composited(over: backgroundImage).cropped(to: bounds)
        context.render(composedFrame, to: destination, bounds: bounds, colorSpace: colorSpace)
        return destination
    }
}
