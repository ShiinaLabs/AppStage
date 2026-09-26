import CoreGraphics

/// Options supplied to an app launched by AppStage.
public struct StageLaunchConfiguration: Sendable {
    public let scenarioID: StageScenarioID?
    public let autoplay: Bool
    public let windowSize: CGSize?

    /// Parses AppStage options from process arguments. The executable name and
    /// arguments owned by the host app are ignored.
    public init(arguments: [String]) throws {
        var scenarioID: StageScenarioID?
        var autoplay = false
        var windowSize: CGSize?
        var seenOptions = Set<String>()

        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--appstage-scenario":
                try Self.markSeen(option, in: &seenOptions)
                let value = try Self.value(after: option, in: arguments, at: index)
                guard !value.isEmpty else {
                    throw StageLaunchConfigurationError.invalidValue(option, value)
                }
                scenarioID = StageScenarioID(value)
                index += 2

            case "--appstage-autoplay":
                try Self.markSeen(option, in: &seenOptions)
                autoplay = true
                index += 1

            case "--appstage-window":
                try Self.markSeen(option, in: &seenOptions)
                let value = try Self.value(after: option, in: arguments, at: index)
                guard let size = Self.parseWindowSize(value) else {
                    throw StageLaunchConfigurationError.invalidValue(option, value)
                }
                windowSize = size
                index += 2

            default:
                index += 1
            }
        }

        self.scenarioID = scenarioID
        self.autoplay = autoplay
        self.windowSize = windowSize
    }

    private static func markSeen(_ option: String, in seenOptions: inout Set<String>) throws {
        guard seenOptions.insert(option).inserted else {
            throw StageLaunchConfigurationError.duplicateOption(option)
        }
    }

    private static func value(after option: String, in arguments: [String], at index: Int) throws -> String {
        let valueIndex = index + 1
        guard arguments.indices.contains(valueIndex), !arguments[valueIndex].hasPrefix("--appstage-") else {
            throw StageLaunchConfigurationError.missingValue(option)
        }
        return arguments[valueIndex]
    }

    private static func parseWindowSize(_ value: String) -> CGSize? {
        let dimensions = value.split(separator: "x", omittingEmptySubsequences: false)
        guard dimensions.count == 2,
              let width = positiveDimension(String(dimensions[0])),
              let height = positiveDimension(String(dimensions[1]))
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private static func positiveDimension(_ value: String) -> CGFloat? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let integer = UInt(value),
              integer > 0
        else {
            return nil
        }
        return CGFloat(integer)
    }
}

public enum StageLaunchConfigurationError: Error, Equatable {
    case missingValue(String)
    case invalidValue(String, String)
    case duplicateOption(String)
}
