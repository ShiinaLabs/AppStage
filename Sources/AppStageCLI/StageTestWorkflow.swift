import AppStage
import Foundation

@MainActor
final class StageTestWorkflow {
    typealias DiscoverCases = @MainActor (Int) async throws -> [StageCaseMetadata]
    typealias RunCase = @MainActor (StageCaseID, Int) async throws -> Void

    struct CaseResult: Equatable {
        let id: String
        let error: String?
    }

    enum Event: Equatable {
        case selected(Int)
        case started(String)
        case finished(CaseResult)
    }

    struct Report {
        let selectedCases: [StageCasePlan.SelectedCase]
        let results: [CaseResult]

        var failureCount: Int { results.filter { $0.error != nil }.count }
    }

    private let discoverCases: DiscoverCases
    private let runCase: RunCase

    init(discoverCases: @escaping DiscoverCases, runCase: @escaping RunCase) {
        self.discoverCases = discoverCases
        self.runCase = runCase
    }

    func run(
        timeout: Int,
        filters: [String],
        exclusions: [String],
        listOnly: Bool,
        onEvent: (Event) -> Void = { _ in }
    ) async throws -> Report {
        let hostCases = try await discoverCases(timeout)
        let selectedCases: [StageCasePlan.SelectedCase]
        do {
            selectedCases = try StageCasePlan.select(
                from: hostCases,
                using: nil,
                kind: .scenario,
                suite: nil,
                includes: filters,
                excludes: exclusions
            )
        } catch StageCasePlanError.noMatchingCases where listOnly {
            return Report(selectedCases: [], results: [])
        }

        guard !listOnly else {
            return Report(selectedCases: selectedCases, results: [])
        }

        onEvent(.selected(selectedCases.count))
        var results: [CaseResult] = []
        for testCase in selectedCases {
            try Task.checkCancellation()
            onEvent(.started(testCase.id))
            let result: CaseResult
            do {
                try await runCase(StageCaseID(testCase.id), timeout)
                result = CaseResult(id: testCase.id, error: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result = CaseResult(id: testCase.id, error: error.localizedDescription)
            }
            results.append(result)
            onEvent(.finished(result))
        }
        return Report(selectedCases: selectedCases, results: results)
    }
}
