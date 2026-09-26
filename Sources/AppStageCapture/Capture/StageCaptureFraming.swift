import CoreGraphics

/// Describes how much desktop to retain around a target window.
public enum StageCaptureFraming: Sendable, Equatable {
    case desktopAroundWindow(horizontalMargin: CGFloat, verticalMargin: CGFloat)
}

public enum StageCaptureGeometryError: Error, Equatable {
    case invalidFrame
    case invalidMargins
    case windowOutsideDisplay
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

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }
}
