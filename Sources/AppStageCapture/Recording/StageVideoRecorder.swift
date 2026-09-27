import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

public enum StageVideoRecorderError: Error, Equatable {
    case alreadyStarted
    case transitionInProgress
    case notStarted
    case outputAlreadyExists
    case writerSetupFailed(String)
    case firstFrameTimedOut
    case noVideoFrames
    case writingFailed(String)
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
    private var filterRefreshFailure: String?
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
        let sourceRect = try StageCaptureGeometry.captureRect(
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
        streamConfiguration.backgroundColor = Self.backgroundColor

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
        let filter = try await StageCaptureDiscovery.displayFilter(
            display: display,
            including: window,
            includingApplicationWindows: configuration.includesApplicationWindows
        )
        let readiness = StageVideoFrameReadiness()
        let output = StageVideoSampleWriter(
            writer: assetWriter,
            input: writerInput,
            frameReadiness: readiness
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
            throw StageVideoRecorderError.writingFailed("Capture filter refresh failed: \(filterRefreshFailure)")
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
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        self.stream = nil
        self.writer = nil
        self.sampleOutput = nil

        if let sampleError = sampleOutput.failureDescription {
            discardOutputIfOwned()
            throw StageVideoRecorderError.writingFailed(sampleError)
        }
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
        filterRefreshFailure = reason
        try? await stream.stopCapture()
    }

    private static let backgroundColor = CGColor(gray: 0, alpha: 1)
}

private final class StageVideoSampleWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let frameReadiness: StageVideoFrameReadiness
    private var didStartSession = false
    private var didAppendFrame = false
    private var storedFailureDescription: String?

    init(writer: AVAssetWriter, input: AVAssetWriterInput, frameReadiness: StageVideoFrameReadiness) {
        self.writer = writer
        self.input = input
        self.frameReadiness = frameReadiness
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

        let accepted = lock.withLock { () -> Bool in
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !didStartSession {
                writer.startSession(atSourceTime: presentationTime)
                didStartSession = true
            }

            guard input.isReadyForMoreMediaData else { return false }
            guard input.append(sampleBuffer) else {
                storedFailureDescription = writer.error?.localizedDescription ?? "The video frame could not be appended."
                return false
            }
            guard !didAppendFrame else { return false }
            didAppendFrame = true
            return true
        }
        if accepted { Task { await frameReadiness.signalFrameAccepted() } }
    }
}
