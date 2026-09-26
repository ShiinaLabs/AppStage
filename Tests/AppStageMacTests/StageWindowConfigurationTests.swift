import CoreGraphics
import XCTest
@testable import AppStageMac

final class StageWindowConfigurationTests: XCTestCase {
    func testCenterAlignmentPositionsTheConfiguredWindowInTheVisibleFrame() {
        let configuration = StageWindowConfiguration(
            size: CGSize(width: 1_100, height: 760),
            alignment: .center
        )

        let frame = configuration.frame(visibleFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))

        XCTAssertEqual(frame, CGRect(x: 410, y: 160, width: 1_100, height: 760))
    }

    func testFramePreservesWindowOriginWhenNoVisibleFrameIsAvailable() {
        let configuration = StageWindowConfiguration(
            size: CGSize(width: 1_100, height: 760),
            alignment: .center
        )

        let frame = configuration.frame(
            currentFrame: CGRect(x: 80, y: 90, width: 800, height: 600),
            visibleFrame: nil
        )

        XCTAssertEqual(frame, CGRect(x: 80, y: 90, width: 1_100, height: 760))
    }
}
