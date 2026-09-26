import Clocks
import XCTest
@testable import AppStage

@MainActor
final class StageCueRunnerTests: XCTestCase {
    func testDueCuesRunInTimeOrderAndDeclarationOrderForTies() async throws {
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)
        let registry = StageActionRegistry()
        var received: [String] = []
        try registry.register(StageActionID("record")) { action in
            received.append(action.arguments["label"] ?? "")
        }
        let scenario = StageScenarioDefinition(
            id: StageScenarioID("sample"),
            duration: .seconds(4),
            cues: [
                StageCue(at: .seconds(2), action: StageAction(id: StageActionID("record"), arguments: ["label": "third"])),
                StageCue(at: .seconds(1), action: StageAction(id: StageActionID("record"), arguments: ["label": "first"])),
                StageCue(at: .seconds(1), action: StageAction(id: StageActionID("record"), arguments: ["label": "second"])),
            ]
        )
        let runner = StageCueRunner(scenario: scenario, playback: playback, registry: registry)

        await playback.play()
        await clock.advance(by: .seconds(3))
        try await runner.runDueCues()

        XCTAssertEqual(received, ["first", "second", "third"])
    }

    func testCueExecutesOnceAcrossRepeatedPositionCrossings() async throws {
        let playback = StagePlayback(clock: TestClock())
        let registry = StageActionRegistry()
        var count = 0
        try registry.register(StageActionID("increment")) { _ in count += 1 }
        let runner = StageCueRunner(
            scenario: .init(id: .init("sample"), duration: .seconds(3), cues: [
                .init(at: .seconds(1), action: .init(id: .init("increment"))),
            ]), playback: playback, registry: registry
        )

        await playback.play()
        await playback.seek(to: .seconds(2))
        try await runner.runDueCues()
        await playback.seek(to: .zero)
        try await runner.runDueCues()
        await playback.seek(to: .seconds(2))
        try await runner.runDueCues()

        XCTAssertEqual(count, 1)
    }

    func testPauseFreezesCuesAndResumeDoesNotReplayThem() async throws {
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)
        let registry = StageActionRegistry()
        var received: [String] = []
        try registry.register(StageActionID("mark")) { action in
            received.append(action.arguments["value"] ?? "")
        }
        let runner = StageCueRunner(
            scenario: .init(id: .init("sample"), duration: .seconds(4), cues: [
                .init(at: .seconds(1), action: .init(id: .init("mark"), arguments: ["value": "one"])),
                .init(at: .seconds(2), action: .init(id: .init("mark"), arguments: ["value": "two"])),
            ]), playback: playback, registry: registry
        )

        await playback.play()
        await clock.advance(by: .seconds(1))
        try await runner.runDueCues()
        await playback.pause()
        await clock.advance(by: .seconds(5))
        try await runner.runDueCues()
        XCTAssertEqual(received, ["one"])

        await playback.play()
        try await runner.runDueCues()
        await clock.advance(by: .seconds(1))
        try await runner.runDueCues()
        XCTAssertEqual(received, ["one", "two"])
    }

    func testResetRearmsCuesEvenWithoutPollingWhileStopped() async throws {
        let playback = StagePlayback(clock: TestClock())
        let registry = StageActionRegistry()
        var count = 0
        try registry.register(StageActionID("increment")) { _ in count += 1 }
        let runner = StageCueRunner(
            scenario: .init(id: .init("sample"), duration: .seconds(3), cues: [
                .init(at: .seconds(1), action: .init(id: .init("increment"))),
            ]), playback: playback, registry: registry
        )

        await playback.play()
        await playback.seek(to: .seconds(2))
        try await runner.runDueCues()
        await playback.reset()
        await playback.play()
        await playback.seek(to: .seconds(2))
        try await runner.runDueCues()

        XCTAssertEqual(count, 2)
    }

    func testUnknownActionFailsRunAndPropagatesError() async throws {
        let playback = StagePlayback(clock: TestClock())
        let registry = StageActionRegistry()
        let runner = StageCueRunner(
            scenario: .init(id: .init("sample"), duration: .seconds(2), cues: [
                .init(at: .zero, action: .init(id: .init("missing"))),
            ]), playback: playback, registry: registry
        )

        await playback.play()
        do {
            try await runner.runDueCues()
            XCTFail("Expected unknown action error")
        } catch {
            XCTAssertEqual(error as? StageActionRegistryError, .unknownAction(.init("missing")))
        }
        XCTAssertEqual(runner.state, .failed)
    }

    func testHandlerFailureStopsLaterCuesUntilReset() async throws {
        enum ExpectedFailure: Error { case rejected }
        let playback = StagePlayback(clock: TestClock())
        let registry = StageActionRegistry()
        var laterCount = 0
        try registry.register(StageActionID("reject")) { _ in throw ExpectedFailure.rejected }
        try registry.register(StageActionID("later")) { _ in laterCount += 1 }
        let runner = StageCueRunner(
            scenario: .init(id: .init("sample"), duration: .seconds(2), cues: [
                .init(at: .zero, action: .init(id: .init("reject"))),
                .init(at: .zero, action: .init(id: .init("later"))),
            ]), playback: playback, registry: registry
        )

        await playback.play()
        do {
            try await runner.runDueCues()
            XCTFail("Expected handler failure")
        } catch {
            XCTAssertTrue(error is ExpectedFailure)
        }
        XCTAssertEqual(runner.state, .failed)
        XCTAssertEqual(laterCount, 0)
        do {
            try await runner.runDueCues()
            XCTFail("Expected retained handler failure")
        } catch {
            XCTAssertTrue(error is ExpectedFailure)
        }
        XCTAssertEqual(laterCount, 0)
    }

    func testOverlappingRunsDoNotExecuteAnInFlightCueTwice() async throws {
        let playback = StagePlayback(clock: TestClock())
        let registry = StageActionRegistry()
        var count = 0
        var release: CheckedContinuation<Void, Never>?
        let started = AsyncStream<Void>.makeStream()
        try registry.register(StageActionID("wait")) { _ in
            count += 1
            if count == 1 {
                started.continuation.yield()
                await withCheckedContinuation { release = $0 }
            }
        }
        let runner = StageCueRunner(
            scenario: .init(id: .init("sample"), duration: .seconds(1), cues: [
                .init(at: .zero, action: .init(id: .init("wait"))),
            ]), playback: playback, registry: registry
        )

        await playback.play()
        let first = Task { try await runner.runDueCues() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        var secondFinished = false
        let second = Task {
            try await runner.runDueCues()
            secondFinished = true
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(secondFinished, "A second caller must await the in-flight handler")
        release?.resume()
        try await first.value
        try await second.value

        XCTAssertEqual(count, 1)
    }

    func testOverlappingRunsBothReceiveHandlerFailure() async throws {
        enum ExpectedFailure: Error { case rejected }
        let playback = StagePlayback(clock: TestClock())
        let registry = StageActionRegistry()
        var release: CheckedContinuation<Void, Never>?
        let started = AsyncStream<Void>.makeStream()
        try registry.register(StageActionID("reject")) { _ in
            started.continuation.yield()
            await withCheckedContinuation { release = $0 }
            throw ExpectedFailure.rejected
        }
        let runner = StageCueRunner(
            scenario: .init(id: .init("sample"), duration: .seconds(1), cues: [
                .init(at: .zero, action: .init(id: .init("reject"))),
            ]), playback: playback, registry: registry
        )

        await playback.play()
        let first = Task { try await runner.runDueCues() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let second = Task { try await runner.runDueCues() }
        for _ in 0..<10 { await Task.yield() }
        release?.resume()

        for call in [first, second] {
            do {
                try await call.value
                XCTFail("Expected shared handler failure")
            } catch {
                XCTAssertTrue(error is ExpectedFailure)
            }
        }
        XCTAssertEqual(runner.state, .failed)
    }

    func testAutomaticDriveRunsCuesAsInjectedClockAdvancesAndCanBeStopped() async throws {
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)
        let registry = StageActionRegistry()
        var received: [String] = []
        try registry.register(StageActionID("mark")) { action in
            received.append(action.arguments["value"] ?? "")
        }
        let runner = StageCueRunner(
            scenario: .init(id: .init("sample"), duration: .seconds(3), cues: [
                .init(at: .seconds(1), action: .init(id: .init("mark"), arguments: ["value": "one"])),
                .init(at: .seconds(2), action: .init(id: .init("mark"), arguments: ["value": "two"])),
            ]), playback: playback, registry: registry
        )

        let drive = runner.start()
        await playback.play()
        await clock.advance(by: .seconds(1))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(received, ["one"])

        runner.stop()
        await clock.advance(by: .seconds(2))
        _ = await drive.result
        XCTAssertEqual(received, ["one"])
    }

    func testAutomaticDriveSurfacesHandlerErrorThroughTaskAndFailedState() async throws {
        enum ExpectedFailure: Error { case rejected }
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)
        let registry = StageActionRegistry()
        try registry.register(StageActionID("reject")) { _ in throw ExpectedFailure.rejected }
        let runner = StageCueRunner(
            scenario: .init(id: .init("sample"), duration: .seconds(2), cues: [
                .init(at: .seconds(1), action: .init(id: .init("reject"))),
            ]), playback: playback, registry: registry
        )

        let drive = runner.start()
        await playback.play()
        await clock.advance(by: .seconds(1))
        do {
            try await drive.value
            XCTFail("Expected handler error")
        } catch {
            XCTAssertTrue(error is ExpectedFailure)
        }
        XCTAssertEqual(runner.state, .failed)
    }

    func testStoppingDriveDuringHandlerSkipsRemainingCues() async throws {
        let playback = StagePlayback(clock: TestClock())
        let registry = StageActionRegistry()
        var release: CheckedContinuation<Void, Never>?
        var laterCount = 0
        let started = AsyncStream<Void>.makeStream()
        try registry.register(StageActionID("wait")) { _ in
            started.continuation.yield()
            await withCheckedContinuation { release = $0 }
        }
        try registry.register(StageActionID("later")) { _ in laterCount += 1 }
        let runner = StageCueRunner(
            scenario: .init(id: .init("sample"), duration: .seconds(1), cues: [
                .init(at: .zero, action: .init(id: .init("wait"))),
                .init(at: .zero, action: .init(id: .init("later"))),
            ]), playback: playback, registry: registry
        )

        await playback.play()
        let drive = runner.start()
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        runner.stop()
        release?.resume()
        _ = await drive.result

        XCTAssertEqual(laterCount, 0)
        XCTAssertEqual(runner.state, .ready)
    }

    func testRegistryRejectsDuplicatesAndRemoveAllClearsHandlers() async throws {
        let registry = StageActionRegistry()
        try registry.register(StageActionID("action")) { _ in }
        XCTAssertThrowsError(try registry.register(StageActionID("action")) { _ in }) { error in
            XCTAssertEqual(error as? StageActionRegistryError, .duplicateAction(.init("action")))
        }
        registry.removeAll()
        do {
            try await registry.execute(.init(id: .init("action")))
            XCTFail("Expected removed action to be unknown")
        } catch {
            XCTAssertEqual(error as? StageActionRegistryError, .unknownAction(.init("action")))
        }
    }

    func testActionCodableRoundTripPreservesArguments() throws {
        let action = StageAction(id: .init("custom"), arguments: ["key": "value"])
        let encoded = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(StageAction.self, from: encoded)
        XCTAssertEqual(decoded, action)
    }
}
