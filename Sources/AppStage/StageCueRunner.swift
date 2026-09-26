public enum StageCueRunnerState: Equatable, Sendable {
    case ready
    case failed
}

/// Runs semantic cues against playback, either on demand or from an automatic drive.
@MainActor
public final class StageCueRunner {
    private let playback: StagePlayback
    private let registry: StageActionRegistry
    private let cues: [StageCue]
    private var nextCueIndex = 0
    private var observedResetGeneration: UInt64?
    private var failure: Error?
    private var isRunning = false
    private var waitingCallers: [CheckedContinuation<Void, Error>] = []
    private var driveTask: Task<Void, Error>?
    private var driveGeneration: UInt64 = 0

    public private(set) var state: StageCueRunnerState = .ready

    public init(scenario: StageScenarioDefinition, playback: StagePlayback, registry: StageActionRegistry) {
        self.playback = playback
        self.registry = registry
        self.cues = scenario.cues.enumerated().sorted {
            if $0.element.at == $1.element.at { return $0.offset < $1.offset }
            return $0.element.at < $1.element.at
        }.map(\.element)
    }

    /// Starts a cancellable drive using playback's injected clock. Repeated starts return the current task.
    /// Await the returned task to observe handler failures; call `stop()` to end the drive.
    @discardableResult
    public func start() -> Task<Void, Error> {
        if let driveTask { return driveTask }
        driveGeneration &+= 1
        let generation = driveGeneration
        let task = Task { [self] in
            defer {
                if driveGeneration == generation { driveTask = nil }
            }
            try await runDueCues()
            while !Task.isCancelled {
                try await playback.sleep(for: .milliseconds(10))
                try await runDueCues()
            }
        }
        driveTask = task
        return task
    }

    /// Cancels the automatic drive. Its returned task then completes with cancellation.
    public func stop() {
        driveGeneration &+= 1
        driveTask?.cancel()
        driveTask = nil
    }

    /// Executes each due cue once. Concurrent callers await the same in-flight pass and error.
    public func runDueCues() async throws {
        if isRunning {
            try await withCheckedThrowingContinuation { waitingCallers.append($0) }
            return
        }
        isRunning = true
        do {
            try await executeDueCues()
            isRunning = false
            let callers = waitingCallers
            waitingCallers.removeAll()
            callers.forEach { $0.resume() }
        } catch {
            isRunning = false
            let callers = waitingCallers
            waitingCallers.removeAll()
            callers.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func executeDueCues() async throws {
        let generation = await playback.resetGeneration
        if let observedResetGeneration, generation != observedResetGeneration {
            nextCueIndex = 0
            failure = nil
            state = .ready
        }
        observedResetGeneration = generation

        if let failure { throw failure }
        guard await playback.state == .playing else { return }
        let position = await playback.position
        while nextCueIndex < cues.count && cues[nextCueIndex].at <= position {
            try Task.checkCancellation()
            guard await playback.state == .playing,
                  await playback.resetGeneration == generation else { return }
            let action = cues[nextCueIndex].action
            do {
                try await registry.execute(action)
                nextCueIndex += 1
            } catch {
                failure = error
                state = .failed
                throw error
            }
        }
    }
}
