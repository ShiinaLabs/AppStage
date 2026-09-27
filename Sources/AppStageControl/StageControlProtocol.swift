import AppStage
import Foundation

public enum StageControlProtocol {
    public static let version = 2
    public static let maximumMessageSize = 1_048_576
}

public enum StageControlError: Error, Codable, Sendable, Equatable, LocalizedError {
    case invalidFrameLength
    case messageTooLarge
    case invalidJSON
    case unknownMessageKind
    case protocolVersionMismatch(expected: Int, actual: Int)
    case invalidToken
    case wrongSessionID
    case wrongBundleID
    case wrongPID
    case invalidState(String)
    case remoteFailure(String)
    case disconnected
    case timedOut(String)
    case unsupported(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrameLength: "Invalid control frame length"
        case .messageTooLarge: "Control message exceeds 1 MiB"
        case .invalidJSON: "Invalid control JSON message"
        case .unknownMessageKind: "Unknown control message kind"
        case let .protocolVersionMismatch(expected, actual): "Control protocol version mismatch (expected \(expected), received \(actual))"
        case .invalidToken: "Control handshake token does not match"
        case .wrongSessionID: "Control session ID does not match"
        case .wrongBundleID: "Control application bundle ID does not match"
        case .wrongPID: "Control application PID does not match"
        case let .invalidState(message): message
        case let .remoteFailure(message): message
        case .disconnected: "Control connection closed"
        case let .timedOut(phase): "Control \(phase) timed out"
        case let .unsupported(feature): "Unsupported control operation: \(feature)"
        case let .transport(message): "Control transport error: \(message)"
        }
    }
}

public struct StageControlHandshake: Codable, Sendable, Equatable {
    public let version: Int
    public let token: String
    public let sessionID: UUID
    public let bundleIdentifier: String
    public let pid: Int32

    public init(version: Int = StageControlProtocol.version, token: String, sessionID: UUID, bundleIdentifier: String, pid: Int32) {
        self.version = version
        self.token = token
        self.sessionID = sessionID
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
    }
}

public struct StageControlIdentity: Sendable {
    public let token: String
    public let sessionID: UUID
    public let bundleIdentifier: String
    public let pid: Int32

    public init(token: String, sessionID: UUID, bundleIdentifier: String, pid: Int32) {
        self.token = token
        self.sessionID = sessionID
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
    }

    public func validate(_ hello: StageControlHandshake) throws {
        guard hello.version == StageControlProtocol.version else {
            throw StageControlError.protocolVersionMismatch(expected: StageControlProtocol.version, actual: hello.version)
        }
        guard hello.token == token else { throw StageControlError.invalidToken }
        guard hello.sessionID == sessionID else { throw StageControlError.wrongSessionID }
        guard hello.bundleIdentifier == bundleIdentifier else { throw StageControlError.wrongBundleID }
        guard hello.pid == pid else { throw StageControlError.wrongPID }
    }
}

public enum StageControlCommand: Codable, Sendable, Equatable {
    case loadScenario(StageScenarioID)
    case prepare
    case play
    case pause
    case reset
    case performAction(StageAction)
    case listScenarios
    case queryState
    case seek(positionMilliseconds: Int64)
}

public struct StageControlRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let command: StageControlCommand

    public init(id: UUID = UUID(), command: StageControlCommand) {
        self.id = id
        self.command = command
    }
}

public enum StageControlState: String, Codable, Sendable {
    case disconnected, connected, scenarioLoaded, preparing, ready, playing, paused, finished, failed
}

public struct StageControlSnapshot: Codable, Sendable, Equatable {
    public let state: StageControlState
    public let scenarioID: StageScenarioID?
    public let positionMilliseconds: Int64?
    public let scenarios: [StageScenarioMetadata]?

    public init(
        state: StageControlState,
        scenarioID: StageScenarioID? = nil,
        positionMilliseconds: Int64? = nil,
        scenarios: [StageScenarioMetadata]? = nil
    ) {
        self.state = state
        self.scenarioID = scenarioID
        self.positionMilliseconds = positionMilliseconds
        self.scenarios = scenarios
    }
}

public enum StageControlResult: Codable, Sendable, Equatable {
    case success(StageControlSnapshot)
    case failure(StageControlError)
}

public struct StageControlResponse: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let result: StageControlResult

    public init(requestID: UUID, result: StageControlResult) {
        self.requestID = requestID
        self.result = result
    }
}

public enum StageControlEventKind: String, Codable, Sendable {
    case ready, playing, paused, finished, failed
}

public struct StageControlEvent: Codable, Sendable, Equatable {
    public let kind: StageControlEventKind
    public let scenarioID: StageScenarioID?
    public let positionMilliseconds: Int64?
    public let error: String?

    public init(kind: StageControlEventKind, scenarioID: StageScenarioID? = nil, positionMilliseconds: Int64? = nil, error: String? = nil) {
        self.kind = kind
        self.scenarioID = scenarioID
        self.positionMilliseconds = positionMilliseconds
        self.error = error
    }
}

public enum StageControlMessage: Codable, Sendable, Equatable {
    case hello(StageControlHandshake)
    case accepted
    case rejected(StageControlError)
    case request(StageControlRequest)
    case response(StageControlResponse)
    case event(StageControlEvent)
}
