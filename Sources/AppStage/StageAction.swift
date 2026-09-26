/// A product-neutral identifier for a semantic action.
public struct StageActionID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
}

/// An action and its string-valued arguments.
public struct StageAction: Codable, Sendable, Equatable {
    public let id: StageActionID
    public let arguments: [String: String]

    public init(id: StageActionID, arguments: [String: String] = [:]) {
        self.id = id
        self.arguments = arguments
    }
}
