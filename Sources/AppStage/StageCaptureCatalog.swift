import Foundation

/// Ordered, Host-owned capture cases grouped into named suites.
public struct StageCaptureSuite: Codable, Sendable, Equatable {
    public let id: String
    public let caseIDs: [StageCaseID]
    public let captureAllSnapshotsDefaults: StageCaptureAllSnapshotsDefaults?

    public init(
        id: String,
        caseIDs: [StageCaseID],
        captureAllSnapshotsDefaults: StageCaptureAllSnapshotsDefaults? = nil
    ) {
        self.id = id
        self.caseIDs = caseIDs
        self.captureAllSnapshotsDefaults = captureAllSnapshotsDefaults
    }
}

/// Defaults for the `capture-all-snapshots` command, supplied by the Host.
public struct StageCaptureAllSnapshotsDefaults: Codable, Sendable, Equatable {
    public let outputDirectory: String?
    public let timeoutSeconds: Int?
    public let horizontalMargin: Double?
    public let verticalMargin: Double?
    public let includeWindowShadow: Bool?
    public let nativeSize: Bool?
    public let includeDemoCursor: Bool?

    public init(
        outputDirectory: String? = nil,
        timeoutSeconds: Int? = nil,
        horizontalMargin: Double? = nil,
        verticalMargin: Double? = nil,
        includeWindowShadow: Bool? = nil,
        nativeSize: Bool? = nil,
        includeDemoCursor: Bool? = nil
    ) {
        self.outputDirectory = outputDirectory
        self.timeoutSeconds = timeoutSeconds
        self.horizontalMargin = horizontalMargin
        self.verticalMargin = verticalMargin
        self.includeWindowShadow = includeWindowShadow
        self.nativeSize = nativeSize
        self.includeDemoCursor = includeDemoCursor
    }
}

/// Complete static-capture discovery information published by a Host.
public struct StageCaptureCatalog: Codable, Sendable, Equatable {
    public let cases: [StageCaseMetadata]
    public let suites: [StageCaptureSuite]
    public let defaultSuite: String?
    public let captureAllSnapshotsDefaults: StageCaptureAllSnapshotsDefaults?

    public init(
        cases: [StageCaseMetadata],
        suites: [StageCaptureSuite] = [],
        defaultSuite: String? = nil,
        captureAllSnapshotsDefaults: StageCaptureAllSnapshotsDefaults? = nil
    ) {
        self.cases = cases
        self.suites = suites
        self.defaultSuite = defaultSuite
        self.captureAllSnapshotsDefaults = captureAllSnapshotsDefaults
    }
}
