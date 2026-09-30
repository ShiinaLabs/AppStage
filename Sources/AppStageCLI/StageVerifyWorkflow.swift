import AVFoundation
import AppStage
import AppStageCapture
import CoreVideo
import Foundation

struct StageVerifyEvent: Codable {
    let timestamp: Date
    let phase: String
    let message: String
    let pid: Int32?
    let durationMilliseconds: Int64?
}

struct StageVerifyAttempt: Codable {
    let scenarioID: String
    let iteration: Int
    var controlSessionID: UUID?
    var pid: Int32?
    var status: String = "fail"
    var failedPhase: String?
    var startedAt: Date
    var finishedAt: Date?
    var totalDuration: Double?
    var controlConnectDuration: Double?
    var loadDuration: Double?
    var prepareDuration: Double?
    var playDuration: Double?
    var finishDuration: Double?
    var recordDuration: Double?
    var processExitCode: Int32?
    var processExitedCleanly = false
    var cleanupPassed = false
    var frameCount: Int = 0
    var firstFrameTimestamp: Double?
    var lastFrameTimestamp: Double?
    var videoDuration: Double?
    var videoWidth: Double?
    var videoHeight: Double?
    var fileSize: Int64?
    var videoOutputMode: String
    var alphaContainsTransparency: Bool?
    var alphaContainsOpaquePixels: Bool?
    var writerFinalizeState: String = "notStarted"
    var conditionResults: [[String: String]] = []
    var axInteractions: [[String: String]] = []
    var conditionTelemetryAvailable = false
    var axTelemetryAvailable = false
    var error: String?
    var events: [StageVerifyEvent] = []

    init(scenarioID: String, iteration: Int, startedAt: Date, videoOutputMode: StageVideoOutputMode = .h264) {
        self.scenarioID = scenarioID
        self.iteration = iteration
        self.startedAt = startedAt
        self.videoOutputMode = videoOutputMode.rawValue
    }
}

struct StageVerifyScenarioSummary: Codable {
    let attempts: Int
    let passed: Int
    let failed: Int
    let passRate: Double

    init(attempts: Int, passed: Int, failed: Int) {
        self.attempts = attempts
        self.passed = passed
        self.failed = failed
        self.passRate = attempts == 0 ? 0 : Double(passed) / Double(attempts)
    }
}

struct StageVerifySummary: Codable {
    let generatedAt: Date
    let iterationsRequested: Int
    let attemptsTotal: Int
    let passed: Int
    let failed: Int
    let perScenario: [String: StageVerifyScenarioSummary]
    let failureCountsByPhase: [String: Int]
    let maxControlConnectDuration: Double?
    let maxPrepareDuration: Double?
    let maxFinalizeDuration: Double?
    let orphanProcessCount: Int
    let cleanupFailureCount: Int
    let determinismWarnings: [String]
    let telemetryNotes: [String]
    let attempts: [StageVerifyAttempt]
    let setupFailurePhase: String?
    let setupFailure: String?
}

enum StageVerifyWorkflow {
    static func validateMovie(
        at url: URL,
        expectedDurationMilliseconds: Int64?,
        requiresAlpha: Bool = false
    ) async throws -> (
        frames: Int, firstPTS: Double, lastPTS: Double, duration: Double,
        width: Double, height: Double, size: Int64,
        alphaContainsTransparency: Bool?, alphaContainsOpaquePixels: Bool?
    ) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= 1_024 else { throw StageVerifyError.invalidMovie("MOV is missing or smaller than 1 KiB") }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard let track = tracks.first(where: { $0.mediaType == .video }) else {
            throw StageVerifyError.invalidMovie("MOV has no video track")
        }
        let duration = try await asset.load(.duration).seconds
        let naturalSize = try await track.load(.naturalSize)
        guard duration.isFinite, duration > 0,
              naturalSize.width.isFinite, naturalSize.height.isFinite,
              naturalSize.width > 0, naturalSize.height > 0 else {
            throw StageVerifyError.invalidMovie("MOV duration or video dimensions are invalid")
        }
        if let expectedDurationMilliseconds, expectedDurationMilliseconds > 0 {
            let expected = Double(expectedDurationMilliseconds) / 1_000
            let lowerBound = max(0.5, expected * 0.5)
            let upperBound = max(expected + 5, expected * 2)
            guard (lowerBound...upperBound).contains(duration) else {
                throw StageVerifyError.invalidMovie("MOV duration \(duration)s is outside expected range \(lowerBound)s–\(upperBound)s")
            }
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        guard reader.canAdd(output) else { throw StageVerifyError.invalidMovie("Could not read video samples") }
        reader.add(output)
        guard reader.startReading() else {
            throw StageVerifyError.invalidMovie(reader.error?.localizedDescription ?? "AVAssetReader could not start")
        }
        var frames = 0
        var previousTime = CMTime.invalid
        var sampleDimensions: CGSize?
        var firstPTS: Double?
        var lastPTS: Double?
        var foundTransparentPixel = false
        var foundVisiblePixel = false
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard time.isValid, time.seconds.isFinite else {
                throw StageVerifyError.invalidMovie("Video frame has an invalid presentation timestamp")
            }
            if previousTime.isValid, CMTimeCompare(time, previousTime) <= 0 {
                throw StageVerifyError.invalidMovie(
                    "Video presentation timestamps are not strictly increasing at frame \(frames): "
                        + "\(previousTime.value)/\(previousTime.timescale) then \(time.value)/\(time.timescale)"
                )
            }
            previousTime = time
            if firstPTS == nil { firstPTS = time.seconds }
            lastPTS = time.seconds
            if let format = CMSampleBufferGetFormatDescription(sample) {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
                if let sampleDimensions, sampleDimensions != size {
                    throw StageVerifyError.invalidMovie("Video dimensions changed during recording")
                }
                sampleDimensions = size
            }
            if requiresAlpha, let imageBuffer = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
                guard CVPixelBufferGetPixelFormatType(imageBuffer) == kCVPixelFormatType_32BGRA,
                      let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer)
                else {
                    throw StageVerifyError.invalidMovie("Transparent MOV could not be decoded as BGRA")
                }
                let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
                let width = CVPixelBufferGetWidth(imageBuffer)
                let height = CVPixelBufferGetHeight(imageBuffer)
                let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height where !foundTransparentPixel || !foundVisiblePixel {
                    let row = bytes.advanced(by: y * bytesPerRow)
                    for x in 0..<width {
                        let alpha = row[x * 4 + 3]
                        if alpha < 255 { foundTransparentPixel = true }
                        if alpha > 0 { foundVisiblePixel = true }
                        if foundTransparentPixel && foundVisiblePixel { break }
                    }
                }
            }
            frames += 1
        }
        guard reader.status == .completed, frames >= 2 else {
            throw StageVerifyError.invalidMovie(reader.error?.localizedDescription ?? "MOV contains fewer than two readable frames")
        }
        guard let firstPTS, let lastPTS else {
            throw StageVerifyError.invalidMovie("MOV contains no timestamped video frames")
        }
        if requiresAlpha {
            guard foundTransparentPixel, foundVisiblePixel else {
                throw StageVerifyError.invalidMovie(
                    "ProRes 4444 MOV must contain both transparent pixels and visible pixels"
                )
            }
        }
        return (
            frames, firstPTS, lastPTS, duration, Double(naturalSize.width), Double(naturalSize.height), size,
            requiresAlpha ? foundTransparentPixel : nil,
            requiresAlpha ? foundVisiblePixel : nil
        )
    }
}

enum StageVerifyError: LocalizedError {
    case invalidMovie(String)

    var errorDescription: String? {
        switch self { case let .invalidMovie(message): message }
    }
}
