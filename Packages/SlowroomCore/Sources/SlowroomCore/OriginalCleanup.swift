import Foundation

public struct OriginalCleanupCandidate: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let bytes: Int64
    let fileURL: URL
    let libraryID: UUID
}

public struct OriginalCleanupPlan: Identifiable, Sendable {
    public let id: UUID
    public let candidates: [OriginalCleanupCandidate]
    public let skippedCount: Int
    public let issues: [String]
    let selections: [URL]
    public var bytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
}

public struct OriginalCleanupResult: Codable, Sendable {
    public var deleted: [String] = []
    public var deletedBytes: Int64 = 0
    public var issues: [String] = []
    public var cancelled = false
    public var completedAt = Date()
    public init() {}
}
