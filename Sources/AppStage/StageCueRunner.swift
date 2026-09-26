public enum StageCueRunnerState: Equatable, Sendable {
    case ready
    case failed
}

/// Runs due cues when the caller advances the playback timeline.
@MainActor
public final class StageCueRunner {
    private let playback: StagePlayback
    private let registry: StageActionRegistry
    private let cues: [StageCue]
    private var nextCueIndex = 0
    private var observedResetGeneration: UInt64?
    private var failure: Error?
    private var isRunning = false

    public private(set) var state: StageCueRunnerState = .ready

    public init(scenario: StageScenarioDefinition, playback: StagePlayback, registry: StageActionRegistry) {
        self.playback = playback
        self.registry = registry
        self.cues = scenario.cues.enumerated().sorted {
            if $0.element.at == $1.element.at { return $0.offset < $1.offset }
            return $0.element.at < $1.element.at
        }.map(\.element)
    }

    /// Executes each due cue once. Call after advancing playback or resuming it.
    public func runDueCues() async throws {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

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
