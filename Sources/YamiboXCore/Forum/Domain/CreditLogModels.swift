import Foundation

public enum CreditLogFilter: String, CaseIterable, Sendable {
    case all
    case income
    case expense
}

public struct CreditLogChange: Equatable, Sendable {
    public let name: String
    public let valueText: String
    public let amount: Int?

    public init(name: String, valueText: String, amount: Int? = nil) {
        self.name = name
        self.valueText = valueText
        self.amount = amount
    }
}

public struct CreditLogEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let operation: String
    public let changes: [CreditLogChange]
    public let description: ForumThreadTextBlock
    public let timeText: String

    public init(
        id: String,
        operation: String,
        changes: [CreditLogChange],
        description: ForumThreadTextBlock,
        timeText: String
    ) {
        self.id = id
        self.operation = operation
        self.changes = changes
        self.description = description
        self.timeText = timeText
    }
}

public struct CreditLogPage: Equatable, Sendable {
    public let entries: [CreditLogEntry]
    public let pageNavigation: ForumPageNavigation?

    public init(entries: [CreditLogEntry], pageNavigation: ForumPageNavigation? = nil) {
        self.entries = entries
        self.pageNavigation = pageNavigation
    }
}
