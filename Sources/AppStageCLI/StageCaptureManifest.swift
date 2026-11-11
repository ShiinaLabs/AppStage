import AppStage
import AppStageCapture
import Foundation

enum StageBatchStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

enum StageBatchScenarioStatus: String, Codable, Sendable {
    case pending
    case recording
    case completed
    case failed
    case cancelled
}

struct StageCaptureManifest: Codable, Equatable, Sendable {
    struct Capture: Codable, Equatable, Sendable {
        let frameRate: Int
        let timeoutSeconds: Int
        let width: Int
        let height: Int
        let horizontalMargin: Double
        let verticalMargin: Double
        let backgroundImage: String?
        let videoOutputMode: StageVideoOutputMode

        private enum CodingKeys: String, CodingKey {
            case frameRate, timeoutSeconds, width, height, horizontalMargin, verticalMargin, backgroundImage, videoOutputMode
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(frameRate, forKey: .frameRate)
            try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
            try container.encode(horizontalMargin, forKey: .horizontalMargin)
            try container.encode(verticalMargin, forKey: .verticalMargin)
            try container.encode(videoOutputMode.rawValue, forKey: .videoOutputMode)
            if let backgroundImage {
                try container.encode(backgroundImage, forKey: .backgroundImage)
            } else {
                try container.encodeNil(forKey: .backgroundImage)
            }
        }
    }

    struct Scenario: Codable, Equatable, Sendable {
        let caseID: String
        let id: String
        let displayName: String?
        let declaredDurationMilliseconds: Int64?
        let output: String
        var status: StageBatchScenarioStatus
        var error: String?

        private enum CodingKeys: String, CodingKey {
            case caseID, id, displayName, declaredDurationMilliseconds, output, status, error
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(caseID, forKey: .caseID)
            try container.encode(id, forKey: .id)
            if let displayName { try container.encode(displayName, forKey: .displayName) }
            else { try container.encodeNil(forKey: .displayName) }
            if let declaredDurationMilliseconds {
                try container.encode(declaredDurationMilliseconds, forKey: .declaredDurationMilliseconds)
            } else {
                try container.encodeNil(forKey: .declaredDurationMilliseconds)
            }
            try container.encode(output, forKey: .output)
            try container.encode(status, forKey: .status)
            if let error { try container.encode(error, forKey: .error) }
            else { try container.encodeNil(forKey: .error) }
        }
    }

    let schemaVersion: Int
    var status: StageBatchStatus
    let bundleIdentifier: String
    let startedAt: String
    var finishedAt: String?
    let casePlanPath: String?
    let suite: String?
    let filters: [String]
    let exclusions: [String]
    let capture: Capture
    var scenarios: [Scenario]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, status, bundleIdentifier, startedAt, finishedAt
        case casePlanPath, suite, filters, exclusions, capture, scenarios
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(status, forKey: .status)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(startedAt, forKey: .startedAt)
        if let finishedAt { try container.encode(finishedAt, forKey: .finishedAt) }
        else { try container.encodeNil(forKey: .finishedAt) }
        try container.encodeIfPresent(casePlanPath, forKey: .casePlanPath)
        try container.encodeIfPresent(suite, forKey: .suite)
        try container.encode(filters, forKey: .filters)
        try container.encode(exclusions, forKey: .exclusions)
        try container.encode(capture, forKey: .capture)
        try container.encode(scenarios, forKey: .scenarios)
    }

    init(
        bundleIdentifier: String,
        captureConfiguration: StageCaptureConfiguration,
        timeoutSeconds: Int = 30,
        horizontalMargin: Double,
        verticalMargin: Double,
        casePlanPath: String? = nil,
        suite: String? = nil,
        filters: [String] = [],
        exclusions: [String] = [],
        startedAt: Date = Date(),
        scenarios: [Scenario]
    ) {
        self.schemaVersion = 2
        self.status = .running
        self.bundleIdentifier = bundleIdentifier
        self.startedAt = Self.timestamp(startedAt)
        self.finishedAt = nil
        self.casePlanPath = casePlanPath
        self.suite = suite
        self.filters = filters
        self.exclusions = exclusions
        let size = captureConfiguration.resolution.pixelSize
        self.capture = Capture(
            frameRate: captureConfiguration.frameRate,
            timeoutSeconds: timeoutSeconds,
            width: Int(size.width),
            height: Int(size.height),
            horizontalMargin: horizontalMargin,
            verticalMargin: verticalMargin,
            backgroundImage: captureConfiguration.canvas?.backgroundImageURL.standardizedFileURL.path,
            videoOutputMode: captureConfiguration.videoOutputMode
        )
        self.scenarios = scenarios
    }

    mutating func finish(_ status: StageBatchStatus, at date: Date = Date()) {
        self.status = status
        finishedAt = Self.timestamp(date)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum StageCaptureOutputNaming {
    static func fileName(for scenarioID: StageScenarioID) throws -> String {
        let safe = String(String.UnicodeScalarView(scenarioID.rawValue.unicodeScalars.map { scalar in
            let value = scalar.value
            let allowed = (65...90).contains(value) || (97...122).contains(value)
                || (48...57).contains(value) || value == 46 || value == 95 || value == 45
            return allowed ? scalar : Unicode.Scalar(45)!
        }))
        guard !safe.isEmpty else { throw StageBatchRecordError.invalidScenarioFilename(scenarioID.rawValue) }
        return safe + ".mov"
    }

    static func collisionKey(for fileName: String) -> String {
        fileName.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

enum StageBatchRecordError: Error, Equatable, LocalizedError {
    case noScenarios
    case outputDirectoryMustBeEmpty
    case invalidScenarioFilename(String)
    case duplicateScenarioID(String)
    case filenameCollision(String)
    case outputAlreadyExists(String)
    case outputDirectoryNotWritable

    var errorDescription: String? {
        switch self {
        case .noScenarios: "No scenarios are available for batch capture."
        case .outputDirectoryMustBeEmpty: "Batch output directory must be empty."
        case let .invalidScenarioFilename(id): "Scenario ID cannot be converted to an output filename: \(id)"
        case let .duplicateScenarioID(id): "Duplicate scenario ID: \(id)"
        case let .filenameCollision(name): "Scenario output filename collision: \(name)"
        case let .outputAlreadyExists(name): "Batch output file already exists: \(name)"
        case .outputDirectoryNotWritable: "Batch output directory is not writable."
        }
    }
}
