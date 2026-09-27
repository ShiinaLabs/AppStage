import AppStage
import XCTest
@testable import AppStageMac

@MainActor
final class StageCursorModelTests: XCTestCase {
    func testFirstMoveAndFirstMoveAfterResetAppearAtTargetWithoutAnimating() async throws {
        let model = StageCursorModel()
        let firstTarget = StagePoint(x: 320, y: 180)

        try await model.move(to: firstTarget, duration: .seconds(1))

        XCTAssertEqual(model.position, firstTarget)
        XCTAssertTrue(model.isVisible)

        model.reset()

        XCTAssertFalse(model.isVisible)
        XCTAssertFalse(model.isClicking)

        let secondTarget = StagePoint(x: 480, y: 260)
        try await model.move(to: secondTarget, duration: .seconds(1))

        XCTAssertEqual(model.position, secondTarget)
        XCTAssertTrue(model.isVisible)
    }

    func testPlaceShowHideAndResetUpdatePresentationState() async throws {
        let model = StageCursorModel()
        let target = StagePoint(x: 260, y: 140)

        try await model.place(at: target)
        XCTAssertEqual(model.position, target)
        XCTAssertFalse(model.isVisible)

        try await model.show(duration: .zero)
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.opacity, 1)

        try await model.hide(duration: .zero)
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(model.opacity, 0)

        try await model.mouseDown()
        model.reset()
        XCTAssertFalse(model.isVisible)
        XCTAssertFalse(model.isMouseDown)
        XCTAssertEqual(model.opacity, 0)
    }

    func testMouseDownUpAndClickExposePressAndReleaseState() async throws {
        let model = StageCursorModel()

        try await model.mouseDown()
        XCTAssertTrue(model.isMouseDown)
        try await model.mouseUp()
        XCTAssertFalse(model.isMouseDown)
        XCTAssertEqual(model.clickFeedbackID, 1)

        try await model.click()
        XCTAssertFalse(model.isMouseDown)
        XCTAssertEqual(model.clickFeedbackID, 2)
    }

    func testTypingStepBuildsVisibleTextOneCharacterAtATime() async throws {
        let model = StageCursorModel()

        try await model.typeText("Studio Mesh", characterInterval: .milliseconds(1))

        XCTAssertEqual(model.typedText, "Studio Mesh")
    }
}
