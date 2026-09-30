import CoreGraphics

public enum StageCaptureResolution: Equatable, Sendable {
    case fullHD
    case custom(width: Int, height: Int)

    public var pixelSize: CGSize {
        switch self {
        case .fullHD:
            CGSize(width: 1_920, height: 1_080)
        case let .custom(width, height):
            CGSize(width: CGFloat(width), height: CGFloat(height))
        }
    }

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .fullHD:
            (1_920, 1_080)
        case let .custom(width, height):
            (width, height)
        }
    }
}

public enum StageCaptureCursor: Equatable, Sendable {
    case hidden
    case visible
}

public enum StageVideoOutputMode: String, Codable, Equatable, Sendable {
    case h264
    case proRes4444Alpha
}

public enum StageCaptureConfigurationError: Error, Equatable {
    case invalidFrameRate
    case invalidResolution
    case invalidFraming
    case canvasResolutionMismatch
    case transparentOutputCannotUseCanvas
}

public struct StageCaptureConfiguration: Equatable, Sendable {
    public let resolution: StageCaptureResolution
    public let frameRate: Int
    public let cursor: StageCaptureCursor
    public let framing: StageCaptureFraming
    public let includesApplicationWindows: Bool
    public let canvas: StageCanvasConfiguration?
    public let videoOutputMode: StageVideoOutputMode

    public init(
        resolution: StageCaptureResolution? = nil,
        frameRate: Int = 60,
        cursor: StageCaptureCursor = .hidden,
        framing: StageCaptureFraming,
        includesApplicationWindows: Bool = false,
        canvas: StageCanvasConfiguration? = nil,
        videoOutputMode: StageVideoOutputMode = .h264
    ) throws {
        guard (1...240).contains(frameRate) else {
            throw StageCaptureConfigurationError.invalidFrameRate
        }

        let resolvedResolution = resolution ?? canvas?.resolution ?? .fullHD
        let dimensions = resolvedResolution.dimensions
        guard dimensions.width >= 2,
              dimensions.height >= 2,
              dimensions.width.isMultiple(of: 2),
              dimensions.height.isMultiple(of: 2)
        else {
            throw StageCaptureConfigurationError.invalidResolution
        }
        if let canvas,
           (dimensions.width != canvas.pixelWidth || dimensions.height != canvas.pixelHeight) {
            throw StageCaptureConfigurationError.canvasResolutionMismatch
        }
        if videoOutputMode == .proRes4444Alpha, canvas != nil {
            throw StageCaptureConfigurationError.transparentOutputCannotUseCanvas
        }

        switch framing {
        case let .desktopAroundWindow(horizontalMargin, verticalMargin):
            guard horizontalMargin.isFinite, verticalMargin.isFinite,
                  horizontalMargin >= 0, verticalMargin >= 0
            else {
                throw StageCaptureConfigurationError.invalidFraming
            }
        }

        self.resolution = resolvedResolution
        self.frameRate = frameRate
        self.cursor = cursor
        self.framing = framing
        self.includesApplicationWindows = includesApplicationWindows
        self.canvas = canvas
        self.videoOutputMode = videoOutputMode
    }
}
