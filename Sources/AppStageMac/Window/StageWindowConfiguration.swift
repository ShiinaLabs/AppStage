import AppKit
import CoreGraphics

/// Describes where an AppStage-controlled window should be placed.
public enum StageWindowAlignment: Sendable {
    case center
}

/// Sets a host app window's size and position without using Accessibility APIs.
public struct StageWindowConfiguration: Sendable {
    public let size: CGSize
    public let alignment: StageWindowAlignment

    public init(size: CGSize, alignment: StageWindowAlignment = .center) {
        self.size = size
        self.alignment = alignment
    }

    /// Returns the configured frame, centered in `visibleFrame` when available.
    /// If no screen is available yet, the current origin is preserved.
    public func frame(currentFrame: CGRect = .zero, visibleFrame: CGRect?) -> CGRect {
        let origin: CGPoint
        switch (alignment, visibleFrame) {
        case let (.center, .some(visibleFrame)):
            origin = CGPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            )
        case (.center, .none):
            origin = currentFrame.origin
        }

        return CGRect(origin: origin, size: size)
    }

    /// Applies the configuration to a window owned by the host application.
    @MainActor
    public func apply(to window: NSWindow) {
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        window.setFrame(
            frame(currentFrame: window.frame, visibleFrame: visibleFrame),
            display: true,
            animate: false
        )
    }
}
