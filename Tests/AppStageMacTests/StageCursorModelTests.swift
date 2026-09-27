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
}
