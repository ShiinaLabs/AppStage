import AppStage

/// Product behavior supplied by each host application, independent of the wire transport.
public protocol StageScenarioControlling: Sendable {
    func loadScenario(_ id: StageScenarioID) async throws
    func prepareScenario() async throws
    func playScenario() async throws
    func pauseScenario() async throws
    func resetScenario() async throws
    func performAction(_ action: StageAction) async throws
    func availableScenarios() async -> [StageScenarioMetadata]
    /// The host emits asynchronous scenario events, especially finished and failed.
    func events() async -> AsyncStream<StageControlEvent>
    /// Called when the controller connection is lost so playback can stop safely.
    func controlDisconnected() async
}

public extension StageScenarioControlling {
    func availableScenarios() async -> [StageScenarioMetadata] { [] }
}
