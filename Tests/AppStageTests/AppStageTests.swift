import Clocks
import CoreGraphics
import XCTest
@testable import AppStage

final class AppStageTests: XCTestCase {
    func testScenarioIDPreservesItsRawValue() {
        let id = StageScenarioID("scenario-a")

        XCTAssertEqual(id.rawValue, "scenario-a")
    }

    func testLaunchConfigurationParsesRecognizedOptionsAndIgnoresOtherArguments() throws {
        let configuration = try StageLaunchConfiguration(arguments: [
            "/Applications/Example.app/Contents/MacOS/Example",
            "--unrelated-option",
            "value",
            "--appstage-scenario",
            "walkthrough",
            "--appstage-autoplay",
            "--appstage-window",
            "1280x800",
        ])

        XCTAssertEqual(configuration.scenarioID, StageScenarioID("walkthrough"))
        XCTAssertTrue(configuration.autoplay)
        XCTAssertEqual(configuration.windowSize, CGSize(width: 1280, height: 800))
    }

    func testLaunchConfigurationDefaultsToNoScenarioNoAutoplayAndNoWindowSize() throws {
        let configuration = try StageLaunchConfiguration(arguments: ["Example"])

        XCTAssertNil(configuration.scenarioID)
        XCTAssertFalse(configuration.autoplay)
        XCTAssertNil(configuration.windowSize)
    }

    func testLaunchConfigurationRejectsMissingScenarioValue() {
        XCTAssertThrowsError(try StageLaunchConfiguration(arguments: ["--appstage-scenario"])) { error in
            XCTAssertEqual(error as? StageLaunchConfigurationError, .missingValue("--appstage-scenario"))
        }
    }

    func testLaunchConfigurationRejectsEmptyScenarioID() {
        XCTAssertThrowsError(try StageLaunchConfiguration(arguments: ["--appstage-scenario", ""])) { error in
            XCTAssertEqual(error as? StageLaunchConfigurationError, .invalidValue("--appstage-scenario", ""))
        }
    }

    func testLaunchConfigurationRejectsMissingWindowSize() {
        XCTAssertThrowsError(try StageLaunchConfiguration(arguments: ["--appstage-window"])) { error in
            XCTAssertEqual(error as? StageLaunchConfigurationError, .missingValue("--appstage-window"))
        }
    }

    func testLaunchConfigurationRejectsNonPositiveOrMalformedWindowSize() {
        for value in ["0x800", "1280x0", "-1x800", "1280x-1", "1280x800.5", "x800", "1280x"] {
            XCTAssertThrowsError(try StageLaunchConfiguration(arguments: ["--appstage-window", value]), value) { error in
                XCTAssertEqual(error as? StageLaunchConfigurationError, .invalidValue("--appstage-window", value))
            }
        }
    }

    func testLaunchConfigurationRejectsDuplicateOptions() {
        XCTAssertThrowsError(try StageLaunchConfiguration(arguments: [
            "--appstage-scenario", "first", "--appstage-scenario", "second",
        ])) { error in
            XCTAssertEqual(error as? StageLaunchConfigurationError, .duplicateOption("--appstage-scenario"))
        }
    }
    func testSequenceUsesTheLatestStepAtOrBeforeTheRequestedTime() {
        let sequence = StageSequence([
            .init(at: .seconds(2), value: "C"),
            .init(at: .seconds(0), value: "A"),
            .init(at: .seconds(1), value: "B"),
        ])

        XCTAssertNil(sequence.value(at: .milliseconds(-1)))
        XCTAssertEqual(sequence.value(at: .milliseconds(999)), "A")
        XCTAssertEqual(sequence.value(at: .milliseconds(1_500)), "B")
        XCTAssertEqual(sequence.value(at: .seconds(2)), "C")
    }

    func testSequenceUsesTheLastDeclaredValueForDuplicateTimes() {
        let sequence = StageSequence([
            StageStep(at: .seconds(1), value: "first"),
            StageStep(at: .seconds(1), value: "last"),
        ])

        XCTAssertEqual(sequence.value(at: .seconds(1)), "last")
    }

    func testPlaybackAdvancesByElapsedClockTime() async {
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)

        await playback.play()
        await clock.advance(by: .seconds(3))

        let position = await playback.position
        let state = await playback.state
        XCTAssertEqual(position, .seconds(3))
        XCTAssertEqual(state, .playing)
    }

    func testPauseFreezesPositionAndResumeContinuesFromThere() async {
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)

        await playback.play()
        await clock.advance(by: .seconds(2))
        await playback.pause()
        await clock.advance(by: .seconds(4))

        let pausedPosition = await playback.position
        let pausedState = await playback.state
        XCTAssertEqual(pausedPosition, .seconds(2))
        XCTAssertEqual(pausedState, .paused)

        await playback.play()
        await clock.advance(by: .seconds(1))
        let resumedPosition = await playback.position
        XCTAssertEqual(resumedPosition, .seconds(3))
    }

    func testResetStopsPlaybackAtZero() async {
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)

        await playback.play()
        await clock.advance(by: .seconds(3))
        await playback.reset()

        let position = await playback.position
        let state = await playback.state
        XCTAssertEqual(position, .zero)
        XCTAssertEqual(state, .stopped)
    }

    func testSeekChangesPositionWithoutStartingPlayback() async {
        let playback = StagePlayback(clock: TestClock())

        await playback.seek(to: .seconds(5))

        let position = await playback.position
        let state = await playback.state
        XCTAssertEqual(position, .seconds(5))
        XCTAssertEqual(state, .stopped)
    }

    func testPlaybackRateChangePreservesPositionContinuity() async {
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)

        await playback.play()
        await clock.advance(by: .seconds(2))
        await playback.setPlaybackRate(2)

        let positionAfterRateChange = await playback.position
        XCTAssertEqual(positionAfterRateChange, .seconds(2))

        await clock.advance(by: .seconds(3))
        let positionAfterAdvance = await playback.position
        XCTAssertEqual(positionAfterAdvance, .seconds(8))
    }

    func testVeryLargeFinitePlaybackRateSaturatesPositionInsteadOfOverflowing() async {
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)

        await playback.seek(to: .seconds(7))
        await playback.play()
        await playback.setPlaybackRate(1e20)
        await clock.advance(by: .seconds(1))

        let position = await playback.position
        XCTAssertEqual(position, .seconds(Int64.max))
    }

    func testPlaybackPositionAdditionSaturatesFromNonzeroSeekBase() async {
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)

        await playback.seek(to: .seconds(Int64.max - 5))
        await playback.play()
        await clock.advance(by: .seconds(10))

        let position = await playback.position
        XCTAssertEqual(position, .seconds(Int64.max))
    }

    func testPlaybackPreservesLargeSeekBaseWhenElapsedTimeIsZero() async {
        let playback = StagePlayback(clock: TestClock())
        let soughtPosition = Duration.seconds(Int64.max - 5)

        await playback.seek(to: soughtPosition)
        await playback.play()

        let position = await playback.position
        XCTAssertEqual(position, soughtPosition)
    }

    func testPlaybackPreservesLargeElapsedTimeAtRateOne() async {
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)

        await playback.play()
        await clock.advance(by: .seconds(Int64.max - 5))

        let position = await playback.position
        XCTAssertEqual(position, .seconds(Int64.max - 5))
    }

    func testPlaybackPositionDoesNotDecreaseWhenCrossingUpperBound() async {
        let clock = TestClock()
        let playback = StagePlayback(clock: clock)

        await playback.seek(to: .seconds(Int64.max - 1))
        await playback.play()
        await clock.advance(by: .milliseconds(1_500))
        let positionBeforeCrossing = await playback.position

        await clock.advance(by: .milliseconds(500))
        let positionAfterCrossing = await playback.position

        XCTAssertGreaterThanOrEqual(positionAfterCrossing, positionBeforeCrossing)
        XCTAssertEqual(positionAfterCrossing, .seconds(Int64.max))
    }
}
