import CoreGraphics
import Foundation

/// Options supplied to an app launched by AppStage.
public struct StageLaunchConfiguration: Sendable {
    public let scenarioID: StageScenarioID?
    public let autoplay: Bool
    public let windowSize: CGSize?
    public let controlHost: String?
    public let controlPort: UInt16?
    public let controlToken: String?
    public let controlSession: UUID?

    /// Parses AppStage options from process arguments. The executable name and
    /// arguments owned by the host app are ignored.
    public init(arguments: [String]) throws {
        var scenarioID: StageScenarioID?
        var autoplay = false
        var windowSize: CGSize?
        var controlHost: String?
        var controlPort: UInt16?
        var controlToken: String?
        var controlSession: UUID?
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

            case "--appstage-control-host":
                try Self.markSeen(option, in: &seenOptions)
                let value = try Self.value(after: option, in: arguments, at: index)
                guard value == "127.0.0.1" else { throw StageLaunchConfigurationError.invalidValue(option, value) }
                controlHost = value
                index += 2

            case "--appstage-control-port":
                try Self.markSeen(option, in: &seenOptions)
                let value = try Self.value(after: option, in: arguments, at: index)
                guard let port = UInt16(value), port > 0 else { throw StageLaunchConfigurationError.invalidValue(option, value) }
                controlPort = port
                index += 2

            case "--appstage-control-token":
                try Self.markSeen(option, in: &seenOptions)
                let value = try Self.value(after: option, in: arguments, at: index)
                guard !value.isEmpty else { throw StageLaunchConfigurationError.invalidValue(option, value) }
                controlToken = value
                index += 2

            case "--appstage-control-session":
                try Self.markSeen(option, in: &seenOptions)
                let value = try Self.value(after: option, in: arguments, at: index)
                guard let session = UUID(uuidString: value) else { throw StageLaunchConfigurationError.invalidValue(option, value) }
                controlSession = session
                index += 2

            default:
                index += 1
            }
        }

        let controlCount = [controlHost != nil, controlPort != nil, controlToken != nil, controlSession != nil]
            .filter { $0 }.count
        guard controlCount == 0 || controlCount == 4 else {
            throw StageLaunchConfigurationError.incompleteControlEndpoint
        }

        self.scenarioID = scenarioID
        self.autoplay = autoplay
        self.windowSize = windowSize
        self.controlHost = controlHost
        self.controlPort = controlPort
        self.controlToken = controlToken
        self.controlSession = controlSession
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
    case incompleteControlEndpoint
}
