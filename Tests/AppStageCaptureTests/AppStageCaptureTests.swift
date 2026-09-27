import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit
import XCTest
@testable import AppStageCapture

final class AppStageCaptureTests: XCTestCase {
    func testRecorderFailureSignalDeliversFirstFailureAndRespondsToCancellation() async throws {
        let signal = StageVideoRecorderFailureSignal()
        let waiter = Task { try await signal.wait() }
        await Task.yield()
        await signal.fail(.writingFailed("root cause"))
        await signal.fail(.writingFailed("later error"))
        do {
            try await waiter.value
        } catch let error as StageVideoRecorderError {
            XCTAssertEqual(error, .writingFailed("root cause"))
        }

        let cancelledSignal = StageVideoRecorderFailureSignal()
        let cancelledWaiter = Task { try await cancelledSignal.wait() }
        cancelledWaiter.cancel()
        do {
            try await cancelledWaiter.value
        } catch is CancellationError {}
    }

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
        XCTAssertFalse(configuration.includesApplicationWindows)
        let controlledConfiguration = try StageCaptureConfiguration(
            framing: .desktopAroundWindow(horizontalMargin: 220, verticalMargin: 120),
            includesApplicationWindows: true
        )
        XCTAssertTrue(controlledConfiguration.includesApplicationWindows)
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

    func testCanvasImageDimensionsDetermineCaptureResolution() throws {
        let backgroundURL = try makePNG(width: 640, height: 360, red: 0.2, green: 0.3, blue: 0.4)
        defer { try? FileManager.default.removeItem(at: backgroundURL.deletingLastPathComponent()) }
        let canvas = try StageCanvasConfiguration(backgroundImageURL: backgroundURL)

        let configuration = try StageCaptureConfiguration(
            framing: .desktopAroundWindow(horizontalMargin: 220, verticalMargin: 120),
            canvas: canvas
        )

        XCTAssertEqual(canvas.pixelWidth, 640)
        XCTAssertEqual(canvas.pixelHeight, 360)
        XCTAssertEqual(configuration.resolution, .custom(width: 640, height: 360))
    }

    func testCanvasConfigurationRejectsUndecodableAndOddSizedImages() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appending(path: "invalid.png")
        try Data("not an image".utf8).write(to: imageURL)

        XCTAssertThrowsError(try StageCanvasConfiguration(backgroundImageURL: imageURL)) {
            XCTAssertEqual($0 as? StageCanvasConfigurationError, .backgroundImageCouldNotBeDecoded)
        }

        let oddImageURL = try makePNG(width: 5, height: 4, red: 0.2, green: 0.3, blue: 0.4)
        defer { try? FileManager.default.removeItem(at: oddImageURL.deletingLastPathComponent()) }
        XCTAssertThrowsError(try StageCanvasConfiguration(backgroundImageURL: oddImageURL)) {
            XCTAssertEqual($0 as? StageCanvasConfigurationError, .dimensionsMustBeEven)
        }
    }

    func testFrameCompositorPreservesBackgroundThroughTransparentPixelsAndOverlaysOpaquePixels() throws {
        let imageURL = try makePNG(width: 2, height: 2, red: 0, green: 0, blue: 1)
        defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }
        let canvas = try StageCanvasConfiguration(backgroundImageURL: imageURL)
        let compositor = try StageFrameCompositor(canvas: canvas)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 2,
            kCVPixelBufferHeightKey as String: 2,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        XCTAssertEqual(CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool), kCVReturnSuccess)
        var source: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &source), kCVReturnSuccess)
        let sourceBuffer = try XCTUnwrap(source)
        let bufferPool = try XCTUnwrap(pool)

        try fill(sourceBuffer, bgra: (0, 0, 0, 0))
        let transparentComposite = try compositor.composite(source: sourceBuffer, pixelBufferPool: bufferPool)
        let transparentPixel = try pixel(transparentComposite)
        XCTAssertEqual(transparentPixel.0, 255)
        XCTAssertEqual(transparentPixel.1, 0)
        XCTAssertEqual(transparentPixel.2, 0)
        XCTAssertEqual(transparentPixel.3, 255)

        try fill(sourceBuffer, bgra: (0, 0, 255, 255))
        let opaqueComposite = try compositor.composite(source: sourceBuffer, pixelBufferPool: bufferPool)
        let opaquePixel = try pixel(opaqueComposite)
        XCTAssertEqual(opaquePixel.0, 0)
        XCTAssertEqual(opaquePixel.1, 0)
        XCTAssertEqual(opaquePixel.2, 255)
        XCTAssertEqual(opaquePixel.3, 255)
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

    func testRecorderFirstFrameReadinessPropagatesCanvasFailure() async {
        let readiness = StageVideoFrameReadiness()
        await readiness.signalFailure("Canvas render failed.")

        do {
            try await readiness.wait(timeout: .seconds(5))
            XCTFail("Expected the canvas failure to fail first-frame readiness.")
        } catch {
            XCTAssertEqual(error as? StageVideoRecorderError, .writingFailed("Canvas render failed."))
        }
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

    private func makePNG(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let imageURL = directory.appending(path: "background.png")
        try StageScreenshot.writePNG(context.makeImage()!, to: imageURL)
        return imageURL
    }

    private func fill(_ pixelBuffer: CVPixelBuffer, bgra: (UInt8, UInt8, UInt8, UInt8)) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                bytes[offset] = bgra.0
                bytes[offset + 1] = bgra.1
                bytes[offset + 2] = bgra.2
                bytes[offset + 3] = bgra.3
            }
        }
    }

    private func pixel(_ pixelBuffer: CVPixelBuffer) throws -> (UInt8, UInt8, UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let offset = (CVPixelBufferGetHeight(pixelBuffer) / 2) * CVPixelBufferGetBytesPerRow(pixelBuffer)
            + (CVPixelBufferGetWidth(pixelBuffer) / 2) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }
}
