import CoreGraphics
import Foundation
import ScreenCaptureKit
import XCTest
@testable import AppStageCapture

final class AppStageCaptureTests: XCTestCase {
    func testDisplayCaptureExcludesEveryOtherWindow() {
        let targetWindowID: CGWindowID = 42
        let windowIDs: [CGWindowID] = [7, targetWindowID, 19]

        XCTAssertEqual(
            StageCaptureDiscovery.windowIDsToExclude(from: windowIDs, except: targetWindowID),
            [7, 19]
        )
    }

    func testDesktopAroundWindowReturnsDisplayRelativeRectIncludingMargins() throws {
        let rect = try StageCaptureGeometry.captureRect(
            windowFrame: CGRect(x: 2_120, y: 200, width: 1_000, height: 700),
            displayFrame: CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080),
            framing: .desktopAroundWindow(horizontalMargin: 100, verticalMargin: 100)
        )

        XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 1_200, height: 900))
    }

    func testCaptureRectClipsMarginsToDisplayBounds() throws {
        let rect = try StageCaptureGeometry.captureRect(
            windowFrame: CGRect(x: 20, y: 10, width: 900, height: 700),
            displayFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            framing: .desktopAroundWindow(horizontalMargin: 220, verticalMargin: 120)
        )

        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1_140, height: 830))
    }

    func testCaptureRectRejectsNegativeMargins() {
        XCTAssertThrowsError(try StageCaptureGeometry.captureRect(
            windowFrame: CGRect(x: 100, y: 100, width: 900, height: 700),
            displayFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            framing: .desktopAroundWindow(horizontalMargin: -1, verticalMargin: 100)
        )) { error in
            XCTAssertEqual(error as? StageCaptureGeometryError, .invalidMargins)
        }
    }

    func testCaptureRectRejectsWindowOutsideDisplay() {
        XCTAssertThrowsError(try StageCaptureGeometry.captureRect(
            windowFrame: CGRect(x: 2_000, y: 100, width: 900, height: 700),
            displayFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            framing: .desktopAroundWindow(horizontalMargin: 10, verticalMargin: 10)
        )) { error in
            XCTAssertEqual(error as? StageCaptureGeometryError, .windowOutsideDisplay)
        }
    }

    func testAspectFitCentersCaptureWithinOutputCanvas() throws {
        let rect = try StageCaptureGeometry.aspectFitRect(
            sourceSize: CGSize(width: 1_340, height: 840),
            outputSize: CGSize(width: 1_920, height: 1_080)
        )

        XCTAssertEqual(rect.minX, 98.5714285714, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 1_722.857142857, accuracy: 0.001)
        XCTAssertEqual(rect.height, 1_080, accuracy: 0.001)
    }

    func testWritePNGCreatesAnImageAtTheRequestedURL() throws {
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let image = try XCTUnwrap(context?.makeImage())
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStage-\(UUID().uuidString)")
            .appendingPathComponent("snapshot.png")
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }

        try StageScreenshot.writePNG(image, to: outputURL)

        let data = try Data(contentsOf: outputURL)
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }

    func testRecordingConfigurationProvidesThePlannedFullHDDefaults() throws {
        let configuration = try StageCaptureConfiguration(
            framing: .desktopAroundWindow(horizontalMargin: 220, verticalMargin: 120)
        )

        XCTAssertEqual(configuration.resolution, .fullHD)
        XCTAssertEqual(configuration.resolution.pixelSize, CGSize(width: 1_920, height: 1_080))
        XCTAssertEqual(configuration.frameRate, 60)
        XCTAssertEqual(configuration.cursor, .hidden)
    }

    func testRecordingConfigurationRejectsInvalidFrameRatesAndVideoDimensions() {
        XCTAssertThrowsError(try StageCaptureConfiguration(
            frameRate: 0,
            framing: .desktopAroundWindow(horizontalMargin: 100, verticalMargin: 100)
        ))
        XCTAssertThrowsError(try StageCaptureConfiguration(
            frameRate: 241,
            framing: .desktopAroundWindow(horizontalMargin: 100, verticalMargin: 100)
        ))
        XCTAssertThrowsError(try StageCaptureConfiguration(
            resolution: .custom(width: 1_921, height: 1_080),
            framing: .desktopAroundWindow(horizontalMargin: 100, verticalMargin: 100)
        ))
        XCTAssertThrowsError(try StageCaptureConfiguration(
            framing: .desktopAroundWindow(horizontalMargin: .infinity, verticalMargin: 100)
        ))
    }

    func testVideoFrameStatusAcceptsOnlyCompleteFrames() {
        XCTAssertTrue(StageVideoFrameStatus.isComplete(SCFrameStatus.complete.rawValue))
        XCTAssertFalse(StageVideoFrameStatus.isComplete(SCFrameStatus.idle.rawValue))
        XCTAssertFalse(StageVideoFrameStatus.isComplete(SCFrameStatus.blank.rawValue))
        XCTAssertFalse(StageVideoFrameStatus.isComplete(SCFrameStatus.suspended.rawValue))
        XCTAssertFalse(StageVideoFrameStatus.isComplete(SCFrameStatus.stopped.rawValue))
        XCTAssertFalse(StageVideoFrameStatus.isComplete(nil))
    }

    func testRecorderFirstFrameReadinessWaitsUntilACompleteFrameArrives() async throws {
        let readiness = StageVideoFrameReadiness()
        let waiter = Task { try await readiness.wait(timeout: .seconds(5)) }
        while await readiness.waiterCount == 0 { await Task.yield() }

        await readiness.signalFrameAccepted()

        try await waiter.value
    }

    func testRecorderLifecycleRejectsStopWhileStartingAndDuplicateStop() throws {
        var lifecycle = StageVideoRecorderLifecycle()

        try lifecycle.beginStart()
        XCTAssertThrowsError(try lifecycle.beginStop()) {
            XCTAssertEqual($0 as? StageVideoRecorderError, .transitionInProgress)
        }
        lifecycle.completeStart()

        try lifecycle.beginStop()
        XCTAssertThrowsError(try lifecycle.beginStop()) {
            XCTAssertEqual($0 as? StageVideoRecorderError, .transitionInProgress)
        }
        lifecycle.completeStop()

        XCTAssertThrowsError(try lifecycle.beginStart()) {
            XCTAssertEqual($0 as? StageVideoRecorderError, .alreadyStarted)
        }
    }
}
