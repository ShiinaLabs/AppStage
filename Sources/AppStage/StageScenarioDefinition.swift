/// The semantic timeline of a scenario.
public struct StageScenarioDefinition: Sendable {
    public let id: StageScenarioID
    public let duration: Duration
    public let cues: [StageCue]

    public init(id: StageScenarioID, duration: Duration, cues: [StageCue]) {
        self.id = id
        self.duration = duration
        self.cues = cues
    }
}
