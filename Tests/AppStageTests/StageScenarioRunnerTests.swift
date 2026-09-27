import AppStage
import Testing

@Suite @MainActor struct StageScenarioRunnerTests {
    @Test func runsActionsConditionsAndWaitsInDeclarationOrder() async throws {
        var events: [String] = []
        let actions = StageActionRegistry()
        try actions.register(StageActionID("ready")) { _ in events.append("action") }
        let conditions = StageConditionRegistry()
        try conditions.register(StageConditionID("visible")) {
            events.append("condition")
            return true
        }
        let runner = makeRunner(
            steps: [
                .perform(StageAction(id: StageActionID("ready"))),
                .waitUntil(StageConditionID("visible"), timeout: .seconds(1)),
                .wait(.milliseconds(15)),
                .finish,
            ], actions: actions, conditions: conditions
        )

        try await runner.start().value

        #expect(events == ["action", "condition"])
        #expect(runner.state == .finished)
    }

    @Test func waitUntilTimesOut() async throws {
        let conditions = StageConditionRegistry()
        try conditions.register(StageConditionID("never")) { false }
        let runner = makeRunner(
            steps: [.waitUntil(StageConditionID("never"), timeout: .milliseconds(45))],
            conditions: conditions
        )

        do {
            try await runner.start().value
            Issue.record("Expected the condition to time out")
        } catch let error as StageConditionRegistryError {
            #expect(error == .timedOut(StageConditionID("never")))
        }
        #expect(runner.state == .failed)
    }

    @Test func actionFailureStopsLaterSteps() async throws {
        enum Expected: Error { case stop }
        var laterActionRan = false
        let actions = StageActionRegistry()
        try actions.register(StageActionID("fail")) { _ in throw Expected.stop }
        try actions.register(StageActionID("later")) { _ in laterActionRan = true }
        let runner = makeRunner(
            steps: [
                .perform(StageAction(id: StageActionID("fail"))),
                .perform(StageAction(id: StageActionID("later"))),
            ], actions: actions
        )

        do {
            try await runner.start().value
            Issue.record("Expected the action to fail")
        } catch is Expected {}
        #expect(!laterActionRan)
        #expect(runner.state == .failed)
    }

    @Test func resolvesTargetAndMovesCursorBeforeClick() async throws {
        let target = StageTargetID("target")
        let targets = StageTargetRegistry()
        try targets.register(target) { StagePoint(x: 24, y: 48) }
        let cursor = TestCursor()
        let runner = makeRunner(
            steps: [.moveCursor(to: target, duration: .milliseconds(1)), .click(target), .finish],
            targets: targets,
            cursor: cursor
        )

        try await runner.start().value

        #expect(cursor.positions == [StagePoint(x: 24, y: 48), StagePoint(x: 24, y: 48)])
        #expect(cursor.clickCount == 1)
    }

    @Test func cancelStopsBeforeFollowingAction() async throws {
        var laterActionRan = false
        let actions = StageActionRegistry()
        try actions.register(StageActionID("later")) { _ in laterActionRan = true }
        let runner = makeRunner(
            steps: [.wait(.seconds(10)), .perform(StageAction(id: StageActionID("later")))],
            actions: actions
        )
        let task = runner.start()
        try await Task.sleep(for: .milliseconds(20))
        runner.cancel()

        do {
            try await task.value
            Issue.record("Expected the runner task to be cancelled")
        } catch is CancellationError {}
        #expect(!laterActionRan)
        #expect(runner.state == .cancelled)
    }

    @Test func cancelledScenarioCanStartAgainFromItsFirstStep() async throws {
        var events: [String] = []
        var conditionChecks = 0
        let actions = StageActionRegistry()
        try actions.register(StageActionID("step")) { _ in events.append("step") }
        try actions.register(StageActionID("complete")) { _ in events.append("complete") }
        let conditions = StageConditionRegistry()
        try conditions.register(StageConditionID("continue")) {
            conditionChecks += 1
            return conditionChecks > 1
        }
        let runner = makeRunner(
            steps: [
                .perform(StageAction(id: StageActionID("step"))),
                .waitUntil(StageConditionID("continue"), timeout: .seconds(2)),
                .perform(StageAction(id: StageActionID("complete"))),
                .finish,
            ],
            actions: actions,
            conditions: conditions
        )

        let firstRun = runner.start()
        for _ in 0..<100 where conditionChecks == 0 { await Task.yield() }
        #expect(conditionChecks > 0)
        runner.cancel()
        do {
            try await firstRun.value
            Issue.record("Expected the first run to be cancelled")
        } catch is CancellationError {}

        try await runner.start().value

        #expect(events == ["step", "step", "complete"])
        #expect(runner.state == .finished)
    }

    @Test func finishedScenarioCanStartAgainFromItsFirstStep() async throws {
        var actionCount = 0
        let actions = StageActionRegistry()
        try actions.register(StageActionID("step")) { _ in actionCount += 1 }
        let runner = makeRunner(
            steps: [.perform(StageAction(id: StageActionID("step"))), .finish],
            actions: actions
        )

        try await runner.start().value
        try await runner.start().value

        #expect(actionCount == 2)
        #expect(runner.state == .finished)
    }

    private func makeRunner(
        steps: [StageScenarioStep],
        actions: StageActionRegistry = StageActionRegistry(),
        conditions: StageConditionRegistry = StageConditionRegistry(),
        targets: StageTargetRegistry = StageTargetRegistry(),
        cursor: TestCursor = TestCursor()
    ) -> StageScenarioRunner {
        StageScenarioRunner(
            script: StageScenarioScript(id: StageScenarioID("test"), steps: steps),
            actions: actions,
            conditions: conditions,
            targets: targets,
            cursor: cursor
        )
    }

    @MainActor private final class TestCursor: StageCursorDriving {
        private(set) var positions: [StagePoint] = []
        private(set) var clickCount = 0
        func move(to point: StagePoint, duration: Duration) async throws { positions.append(point) }
        func click() async throws { clickCount += 1 }
    }
}
