import CoreGraphics
import Foundation

/// Describes how much desktop to retain around a target window.
public enum StageCaptureFraming: Sendable, Equatable {
    case desktopAroundWindow(horizontalMargin: CGFloat, verticalMargin: CGFloat)
}

public enum StageCaptureGeometryError: Error, Equatable, LocalizedError {
    case invalidFrame
    case invalidMargins
    case windowOutsideDisplay
    case windowSpansMultipleDisplays
    case framingOutsideDisplay

    public var errorDescription: String? {
        switch self {
        case .invalidFrame: "Capture window and display frames must have finite, positive dimensions."
        case .invalidMargins: "Capture margins must be finite and non-negative."
        case .windowOutsideDisplay: "Capture window does not intersect the selected display."
        case .windowSpansMultipleDisplays:
            "Capture window must fit entirely within one display; spanning displays or extending beyond display bounds is unsupported."
        case .framingOutsideDisplay:
            "Requested capture framing does not fit entirely on the selected display."
        }
    }
}

public enum StageCaptureGeometry {
    /// Calculates the largest centered rectangle with `sourceSize`'s aspect ratio
    /// that fits inside the output canvas.
    public static func aspectFitRect(sourceSize: CGSize, outputSize: CGSize) throws -> CGRect {
        guard isUsable(CGRect(origin: .zero, size: sourceSize)),
              isUsable(CGRect(origin: .zero, size: outputSize))
        else {
            throw StageCaptureGeometryError.invalidFrame
        }

        let scale = min(outputSize.width / sourceSize.width, outputSize.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(
            x: (outputSize.width - size.width) / 2,
            y: (outputSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Calculates a crop in display-local logical points around a window.
    ///
    /// `windowFrame` and `displayFrame` must use the same global coordinate space.
    /// The result is clipped to the display and translated so its origin is the
    /// display's top-left origin in ScreenCaptureKit's source coordinate space.
    public static func captureRect(
        windowFrame: CGRect,
        displayFrame: CGRect,
        framing: StageCaptureFraming
    ) throws -> CGRect {
        guard isUsable(windowFrame), isUsable(displayFrame) else {
            throw StageCaptureGeometryError.invalidFrame
        }

        let horizontalMargin: CGFloat
        let verticalMargin: CGFloat
        switch framing {
        case let .desktopAroundWindow(horizontal, vertical):
            horizontalMargin = horizontal
            verticalMargin = vertical
        }

        guard horizontalMargin.isFinite, verticalMargin.isFinite,
              horizontalMargin >= 0, verticalMargin >= 0
        else {
            throw StageCaptureGeometryError.invalidMargins
        }

        guard !windowFrame.intersection(displayFrame).isNull,
              !windowFrame.intersection(displayFrame).isEmpty
        else {
            throw StageCaptureGeometryError.windowOutsideDisplay
        }

        let expandedFrame = CGRect(
            x: windowFrame.minX - horizontalMargin,
            y: windowFrame.minY - verticalMargin,
            width: windowFrame.width + horizontalMargin * 2,
            height: windowFrame.height + verticalMargin * 2
        )
        let clippedFrame = expandedFrame.intersection(displayFrame)
        guard !clippedFrame.isNull, !clippedFrame.isEmpty else {
            throw StageCaptureGeometryError.windowOutsideDisplay
        }

        return CGRect(
            x: clippedFrame.minX - displayFrame.minX,
            y: clippedFrame.minY - displayFrame.minY,
            width: clippedFrame.width,
            height: clippedFrame.height
        )
    }

    /// Calculates an unclipped video crop and rejects windows or requested margins
    /// that do not fit entirely within the selected display.
    public static func strictCaptureRect(
        windowFrame: CGRect,
        displayFrame: CGRect,
        framing: StageCaptureFraming
    ) throws -> CGRect {
        guard isUsable(windowFrame), isUsable(displayFrame) else {
            throw StageCaptureGeometryError.invalidFrame
        }
        let (horizontalMargin, verticalMargin) = try margins(for: framing)
        let intersection = windowFrame.intersection(displayFrame)
        guard !intersection.isNull, !intersection.isEmpty else {
            throw StageCaptureGeometryError.windowOutsideDisplay
        }
        guard displayFrame.contains(windowFrame) else {
            throw StageCaptureGeometryError.windowSpansMultipleDisplays
        }

        let expandedFrame = CGRect(
            x: windowFrame.minX - horizontalMargin,
            y: windowFrame.minY - verticalMargin,
            width: windowFrame.width + horizontalMargin * 2,
            height: windowFrame.height + verticalMargin * 2
        )
        guard displayFrame.contains(expandedFrame) else {
            throw StageCaptureGeometryError.framingOutsideDisplay
        }
        return CGRect(
            x: expandedFrame.minX - displayFrame.minX,
            y: expandedFrame.minY - displayFrame.minY,
            width: expandedFrame.width,
            height: expandedFrame.height
        )
    }

    private static func margins(for framing: StageCaptureFraming) throws -> (CGFloat, CGFloat) {
        let horizontalMargin: CGFloat
        let verticalMargin: CGFloat
        switch framing {
        case let .desktopAroundWindow(horizontal, vertical):
            horizontalMargin = horizontal
            verticalMargin = vertical
        }
        guard horizontalMargin.isFinite, verticalMargin.isFinite,
              horizontalMargin >= 0, verticalMargin >= 0 else {
            throw StageCaptureGeometryError.invalidMargins
        }
        return (horizontalMargin, verticalMargin)
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }
}
