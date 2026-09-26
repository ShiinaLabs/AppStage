public enum StageActionRegistryError: Error, Equatable, Sendable {
    case duplicateAction(StageActionID)
    case unknownAction(StageActionID)
}

/// An instance-owned collection of semantic action handlers.
@MainActor
public final class StageActionRegistry {
    public typealias Handler = @MainActor (StageAction) async throws -> Void
    private var handlers: [StageActionID: Handler] = [:]

    public init() {}

    public func register(_ id: StageActionID, handler: @escaping Handler) throws {
        guard handlers[id] == nil else { throw StageActionRegistryError.duplicateAction(id) }
        handlers[id] = handler
    }

    public func execute(_ action: StageAction) async throws {
        guard let handler = handlers[action.id] else {
            throw StageActionRegistryError.unknownAction(action.id)
        }
        try await handler(action)
    }

    public func removeAll() {
        handlers.removeAll()
    }
}
