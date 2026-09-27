import Foundation

/// A stable, product-neutral identifier for an interactive scenario condition.
public struct StageConditionID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
}

/// A stable identifier for a target supplied by the host application's current layout.
public struct StageTargetID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
}

/// A two-dimensional point in the host's cursor overlay coordinate space.
public struct StagePoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A single ordered operation in a host-driven scenario.
public enum StageScenarioStep: Sendable {
    case perform(StageAction)
    case wait(Duration)
    case waitUntil(StageConditionID, timeout: Duration)
    case moveCursor(to: StageTargetID, duration: Duration)
    case click(StageTargetID)
    case finish
}

/// A linear scenario script. Timeline cues remain available for deterministic data playback.
public struct StageScenarioScript: Sendable {
    public let id: StageScenarioID
    public let displayName: String?
    public let duration: Duration?
    public let steps: [StageScenarioStep]

    public init(
        id: StageScenarioID,
        displayName: String? = nil,
        duration: Duration? = nil,
        steps: [StageScenarioStep]
    ) {
        self.id = id
        self.displayName = displayName
        self.duration = duration
        self.steps = steps
    }
}

/// Small host-provided description returned by scenario discovery.
public struct StageScenarioMetadata: Codable, Sendable, Equatable {
    public let id: StageScenarioID
    public let displayName: String?
    public let durationMilliseconds: Int64?

    public init(id: StageScenarioID, displayName: String? = nil, durationMilliseconds: Int64? = nil) {
        self.id = id
        self.displayName = displayName
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum StageConditionRegistryError: Error, Equatable, Sendable, LocalizedError {
    case duplicateCondition(StageConditionID)
    case unknownCondition(StageConditionID)
    case timedOut(StageConditionID)

    public var errorDescription: String? {
        switch self {
        case let .duplicateCondition(id): "Duplicate condition: \(id.rawValue)"
        case let .unknownCondition(id): "Unknown condition: \(id.rawValue)"
        case let .timedOut(id): "Condition timed out: \(id.rawValue)"
        }
    }
}

/// An instance-owned collection of asynchronous host state conditions.
@MainActor
public final class StageConditionRegistry {
    public typealias Handler = @MainActor @Sendable () async throws -> Bool
    private var handlers: [StageConditionID: Handler] = [:]

    public init() {}

    public func register(_ id: StageConditionID, handler: @escaping Handler) throws {
        guard handlers[id] == nil else { throw StageConditionRegistryError.duplicateCondition(id) }
        handlers[id] = handler
    }

    public func waitUntil(
        _ id: StageConditionID,
        timeout: Duration,
        pollingInterval: Duration = .milliseconds(25)
    ) async throws {
        guard let handler = handlers[id] else { throw StageConditionRegistryError.unknownCondition(id) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if try await handler() { return }
            try await Task.sleep(for: min(pollingInterval, max(.zero, clock.now.duration(to: deadline))))
        }
        try Task.checkCancellation()
        if try await handler() { return }
        throw StageConditionRegistryError.timedOut(id)
    }

    public func removeAll() { handlers.removeAll() }
}

public enum StageTargetRegistryError: Error, Equatable, Sendable, LocalizedError {
    case duplicateTarget(StageTargetID)
    case unknownTarget(StageTargetID)
    case unavailableTarget(StageTargetID)

    public var errorDescription: String? {
        switch self {
        case let .duplicateTarget(id): "Duplicate cursor target: \(id.rawValue)"
        case let .unknownTarget(id): "Unknown cursor target: \(id.rawValue)"
        case let .unavailableTarget(id): "Cursor target is not currently visible: \(id.rawValue)"
        }
    }
}

/// Resolves semantic targets against the host's current presentation geometry.
@MainActor
public final class StageTargetRegistry {
    public typealias Resolver = @MainActor @Sendable () async throws -> StagePoint?
    private var resolvers: [StageTargetID: Resolver] = [:]

    public init() {}

    public func register(_ id: StageTargetID, resolver: @escaping Resolver) throws {
        guard resolvers[id] == nil else { throw StageTargetRegistryError.duplicateTarget(id) }
        resolvers[id] = resolver
    }

    public func resolve(_ id: StageTargetID) async throws -> StagePoint {
        guard let resolver = resolvers[id] else { throw StageTargetRegistryError.unknownTarget(id) }
        guard let point = try await resolver() else { throw StageTargetRegistryError.unavailableTarget(id) }
        return point
    }

    public func removeAll() { resolvers.removeAll() }
}

@MainActor
public protocol StageCursorDriving: AnyObject {
    func move(to point: StagePoint, duration: Duration) async throws
    func click() async throws
}

public enum StageScenarioRunnerState: Equatable, Sendable {
    case idle, running, finished, failed, cancelled
}

/// Runs a scenario's steps in order and stops at the first failure or cancellation.
@MainActor
public final class StageScenarioRunner {
    private let script: StageScenarioScript
    private let actions: StageActionRegistry
    private let conditions: StageConditionRegistry
    private let targets: StageTargetRegistry
    private let cursor: any StageCursorDriving
    private var runTask: Task<Void, Error>?

    public private(set) var state: StageScenarioRunnerState = .idle

    public init(
        script: StageScenarioScript,
        actions: StageActionRegistry,
        conditions: StageConditionRegistry,
        targets: StageTargetRegistry,
        cursor: any StageCursorDriving
    ) {
        self.script = script
        self.actions = actions
        self.conditions = conditions
        self.targets = targets
        self.cursor = cursor
    }

    @discardableResult
    public func start() -> Task<Void, Error> {
        if let runTask { return runTask }
        state = .running
        let task = Task { [self] in
            do {
                for step in script.steps {
                    try Task.checkCancellation()
                    switch step {
                    case let .perform(action):
                        try await actions.execute(action)
                    case let .wait(duration):
                        try await Task.sleep(for: duration)
                    case let .waitUntil(condition, timeout):
                        try await conditions.waitUntil(condition, timeout: timeout)
                    case let .moveCursor(target, duration):
                        let point = try await targets.resolve(target)
                        try await cursor.move(to: point, duration: duration)
                    case let .click(target):
                        let point = try await targets.resolve(target)
                        try await cursor.move(to: point, duration: .zero)
                        try await cursor.click()
                    case .finish:
                        state = .finished
                        return
                    }
                }
                state = .finished
            } catch is CancellationError {
                state = .cancelled
                throw CancellationError()
            } catch {
                state = .failed
                throw error
            }
        }
        runTask = task
        return task
    }

    public func cancel() {
        guard state == .running else { return }
        runTask?.cancel()
    }
}
