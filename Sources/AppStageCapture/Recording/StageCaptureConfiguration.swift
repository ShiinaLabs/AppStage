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

public enum StageCaptureConfigurationError: Error, Equatable {
    case invalidFrameRate
    case invalidResolution
    case invalidFraming
}

public struct StageCaptureConfiguration: Equatable, Sendable {
    public let resolution: StageCaptureResolution
    public let frameRate: Int
    public let cursor: StageCaptureCursor
    public let framing: StageCaptureFraming

    public init(
        resolution: StageCaptureResolution = .fullHD,
        frameRate: Int = 60,
        cursor: StageCaptureCursor = .hidden,
        framing: StageCaptureFraming
    ) throws {
        guard (1...240).contains(frameRate) else {
            throw StageCaptureConfigurationError.invalidFrameRate
        }

        let dimensions = resolution.dimensions
        guard dimensions.width >= 2,
              dimensions.height >= 2,
              dimensions.width.isMultiple(of: 2),
              dimensions.height.isMultiple(of: 2)
        else {
            throw StageCaptureConfigurationError.invalidResolution
        }

        switch framing {
        case let .desktopAroundWindow(horizontalMargin, verticalMargin):
            guard horizontalMargin.isFinite, verticalMargin.isFinite,
                  horizontalMargin >= 0, verticalMargin >= 0
            else {
                throw StageCaptureConfigurationError.invalidFraming
            }
        }

        self.resolution = resolution
        self.frameRate = frameRate
        self.cursor = cursor
        self.framing = framing
    }
}
