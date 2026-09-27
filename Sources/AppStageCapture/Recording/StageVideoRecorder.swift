import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

public enum StageVideoRecorderError: Error, Equatable, Sendable, LocalizedError {
    case alreadyStarted
    case transitionInProgress
    case notStarted
    case outputAlreadyExists
    case writerSetupFailed(String)
    case firstFrameTimedOut
    case noVideoFrames
    case writingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: "The recorder has already started."
        case .transitionInProgress: "The recorder is transitioning."
        case .notStarted: "The recorder has not started."
        case .outputAlreadyExists: "The output file already exists."
        case let .writerSetupFailed(message), let .writingFailed(message): message
        case .firstFrameTimedOut: "Timed out waiting for the first recorded frame."
        case .noVideoFrames: "No video frames were recorded."
        }
    }
}

/// Records a display crop to a QuickTime MOV using ScreenCaptureKit and AVAssetWriter.
public actor StageVideoRecorder {
    private let window: StageCaptureWindow
    private let display: StageCaptureDisplay
    private let configuration: StageCaptureConfiguration
    private let outputURL: URL

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var sampleOutput: StageVideoSampleWriter?
    private var filterRefreshTask: Task<Void, Never>?
    private var filterRefreshFailure: StageVideoRecorderError?
    private let failureSignal = StageVideoRecorderFailureSignal()
    private var lifecycle = StageVideoRecorderLifecycle()
    private var ownsOutputFile = false

    public init(
        window: StageCaptureWindow,
        display: StageCaptureDisplay,
        configuration: StageCaptureConfiguration,
        outputURL: URL
    ) {
        self.window = window
        self.display = display
        self.configuration = configuration
        self.outputURL = outputURL
    }

    public func start() async throws {
        try lifecycle.beginStart()
        do {
            try await startCapture()
            lifecycle.completeStart()
            startFilterRefresh()
        } catch {
            filterRefreshTask?.cancel()
            filterRefreshTask = nil
            if let stream {
                try? await stream.stopCapture()
            }
            writer?.cancelWriting()
            discardOutputIfOwned()
            self.stream = nil
            self.writer = nil
            self.sampleOutput = nil
            lifecycle.failStart()
            throw error
        }
    }

    private func startCapture() async throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw StageVideoRecorderError.outputAlreadyExists
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dimensions = configuration.resolution.dimensions
        let sourceRect = try StageCaptureGeometry.strictCaptureRect(
            windowFrame: window.frame,
            displayFrame: display.frame,
            framing: configuration.framing
        )
        let destinationRect = try StageCaptureGeometry.aspectFitRect(
            sourceSize: sourceRect.size,
            outputSize: configuration.resolution.pixelSize
        )
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.sourceRect = sourceRect
        streamConfiguration.width = dimensions.width
        streamConfiguration.height = dimensions.height
        streamConfiguration.destinationRect = destinationRect
        streamConfiguration.preservesAspectRatio = true
        streamConfiguration.showsCursor = configuration.cursor == .visible
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(configuration.frameRate))
        streamConfiguration.queueDepth = 8
        if configuration.canvas != nil {
            streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
            streamConfiguration.backgroundColor = Self.clearBackgroundColor
        } else {
            streamConfiguration.backgroundColor = Self.backgroundColor
        }

        let frameCompositor = try configuration.canvas.map(StageFrameCompositor.init(canvas:))

        let assetWriter: AVAssetWriter
        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw StageVideoRecorderError.writerSetupFailed(error.localizedDescription)
        }

        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: dimensions.width,
                AVVideoHeightKey: dimensions.height,
            ]
        )
        writerInput.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(writerInput) else {
            throw StageVideoRecorderError.writerSetupFailed("The video input cannot be added.")
        }
        assetWriter.add(writerInput)
        let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        if configuration.canvas != nil {
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: writerInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: dimensions.width,
                    kCVPixelBufferHeightKey as String: dimensions.height,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ]
            )
        } else {
            pixelBufferAdaptor = nil
        }
        let filter = try await StageCaptureDiscovery.displayFilter(
            display: display,
            including: window,
            includingApplicationWindows: configuration.includesApplicationWindows
        )
        let readiness = StageVideoFrameReadiness()
        let output = StageVideoSampleWriter(
            writer: assetWriter,
            input: writerInput,
            pixelBufferAdaptor: pixelBufferAdaptor,
            frameCompositor: frameCompositor,
            frameReadiness: readiness,
            failureSignal: failureSignal
        )
        let captureStream = SCStream(filter: filter, configuration: streamConfiguration, delegate: nil)
        try captureStream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.shiinalabs.appstage.video-writer")
        )

        self.writer = assetWriter
        self.sampleOutput = output
        self.stream = captureStream

        guard assetWriter.startWriting() else {
            assetWriter.cancelWriting()
            throw StageVideoRecorderError.writerSetupFailed(
                assetWriter.error?.localizedDescription ?? "AVAssetWriter could not start."
            )
        }
        ownsOutputFile = true

        try await captureStream.startCapture()
        try await output.waitForFirstFrame(timeout: .seconds(5))
    }

    /// Removes only a MOV whose writer was successfully started by this recorder.
    public func discardOutputIfOwned() {
        guard ownsOutputFile else { return }
        try? FileManager.default.removeItem(at: outputURL)
        ownsOutputFile = false
    }

    /// Suspends until a fatal runtime recording error occurs, or throws when cancelled.
    public func waitForFailure() async throws -> Never {
        try await failureSignal.wait()
    }

    public func stop() async throws {
        try lifecycle.beginStop()
        defer { lifecycle.completeStop() }

        guard let stream, let writer, let sampleOutput else {
            throw StageVideoRecorderError.notStarted
        }

        filterRefreshTask?.cancel()
        await filterRefreshTask?.value
        filterRefreshTask = nil

        if let filterRefreshFailure {
            sampleOutput.finishInput()
            writer.cancelWriting()
            self.stream = nil
            self.writer = nil
            self.sampleOutput = nil
            discardOutputIfOwned()
            throw filterRefreshFailure
        }

        do {
            try await stream.stopCapture()
        } catch {
            writer.cancelWriting()
            self.stream = nil
            self.writer = nil
            self.sampleOutput = nil
            discardOutputIfOwned()
            throw error
        }

        sampleOutput.finishInput()
        if let sampleError = sampleOutput.failureDescription {
            writer.cancelWriting()
            self.stream = nil
            self.writer = nil
            self.sampleOutput = nil
            discardOutputIfOwned()
            throw StageVideoRecorderError.writingFailed(sampleError)
        }
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        self.stream = nil
        self.writer = nil
        self.sampleOutput = nil

        guard sampleOutput.didCaptureVideo else {
            discardOutputIfOwned()
            throw StageVideoRecorderError.noVideoFrames
        }
        guard writer.status == .completed else {
            discardOutputIfOwned()
            throw StageVideoRecorderError.writingFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter did not finish the MOV."
            )
        }
        ownsOutputFile = false
    }

    private func startFilterRefresh() {
        guard !configuration.includesApplicationWindows else { return }
        guard let stream else { return }
        let display = self.display
        let window = self.window
        let configuration = self.configuration
        filterRefreshFailure = nil
        filterRefreshTask = Task { [weak self, stream, display, window, configuration] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    let filter = try await StageCaptureDiscovery.displayFilter(
                        display: display,
                        including: window,
                        includingApplicationWindows: configuration.includesApplicationWindows
                    )
                    try await stream.updateContentFilter(filter)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.stopAfterFilterRefreshFailure(
                        error.localizedDescription,
                        stream: stream
                    )
                    return
                }
            }
        }
    }

    private func stopAfterFilterRefreshFailure(_ reason: String, stream: SCStream) async {
        let failure = StageVideoRecorderError.writingFailed("Capture filter refresh failed: \(reason)")
        if filterRefreshFailure == nil { filterRefreshFailure = failure }
        await failureSignal.fail(failure)
        try? await stream.stopCapture()
    }

    private static let backgroundColor = CGColor(gray: 0, alpha: 1)
    private static let clearBackgroundColor = CGColor(gray: 0, alpha: 0)
}

private final class StageVideoSampleWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    private enum Result {
        case skipped
        case acceptedFirstFrame
        case failed(StageVideoRecorderError)
    }

    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let frameCompositor: StageFrameCompositor?
    private let frameReadiness: StageVideoFrameReadiness
    private let failureSignal: StageVideoRecorderFailureSignal
    private var didStartSession = false
    private var didAppendFrame = false
    private var storedFailureDescription: String?

    init(
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?,
        frameCompositor: StageFrameCompositor?,
        frameReadiness: StageVideoFrameReadiness,
        failureSignal: StageVideoRecorderFailureSignal
    ) {
        self.writer = writer
        self.input = input
        self.pixelBufferAdaptor = pixelBufferAdaptor
        self.frameCompositor = frameCompositor
        self.frameReadiness = frameReadiness
        self.failureSignal = failureSignal
    }

    var didCaptureVideo: Bool {
        lock.withLock { didAppendFrame }
    }

    var failureDescription: String? {
        lock.withLock { storedFailureDescription }
    }

    func finishInput() {
        lock.withLock { input.markAsFinished() }
    }

    func waitForFirstFrame(timeout: Duration) async throws {
        try await frameReadiness.wait(timeout: timeout)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              StageVideoFrameStatus.isComplete(attachments[.status] as? Int)
        else {
            return
        }

        let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let result = lock.withLock { () -> Result in
            if storedFailureDescription != nil { return .skipped }
            if writer.status == .failed {
                return failLocked(writer.error?.localizedDescription ?? "AVAssetWriter failed while recording.")
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !didStartSession {
                writer.startSession(atSourceTime: presentationTime)
                didStartSession = true
            }

            guard sourceBuffer != nil else {
                return failLocked(StageFrameCompositorError.sourceFrameUnavailable.localizedDescription)
            }

            guard input.isReadyForMoreMediaData else {
                return failLocked("Video writer could not keep up with captured frames.")
            }
            let didAppend: Bool
            if let frameCompositor, let pixelBufferAdaptor {
                guard let sourceBuffer else { return .skipped }
                do {
                    let compositeBuffer = try frameCompositor.composite(
                        source: sourceBuffer,
                        pixelBufferPool: pixelBufferAdaptor.pixelBufferPool
                    )
                    didAppend = pixelBufferAdaptor.append(
                        compositeBuffer,
                        withPresentationTime: presentationTime
                    )
                } catch {
                    return failLocked(error.localizedDescription)
                }
            } else {
                didAppend = input.append(sampleBuffer)
            }
            guard didAppend else {
                let reason = writer.error?.localizedDescription ?? "The video frame could not be appended."
                return failLocked(reason)
            }
            guard !didAppendFrame else { return .skipped }
            didAppendFrame = true
            return .acceptedFirstFrame
        }
        switch result {
        case .skipped:
            break
        case .acceptedFirstFrame:
            Task { await frameReadiness.signalFrameAccepted() }
        case let .failed(error):
            Task {
                await frameReadiness.signalFailure(error.localizedDescription)
                await failureSignal.fail(error)
            }
        }
    }

    private func failLocked(_ reason: String) -> Result {
        if storedFailureDescription == nil { storedFailureDescription = reason }
        return .failed(.writingFailed(storedFailureDescription ?? reason))
    }
}
