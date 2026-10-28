import Foundation

/// Lifecycle phase of a managed transfer task.
public enum RemoteTransferPhase: String, Sendable, Hashable, Codable {
    case preparing
    case transferring
    case verifying
    case committing
    case completed
    case cancelled
    case failed
    case needsAuthorization
    case reconciling
}

/// A monotonic task-local progress observation. Byte counts may reset between
/// attempts; `attempt` and `sequence` make that explicit to observers.
public struct RemoteTransferProgress: Sendable, Hashable, Codable {
    public let phase: RemoteTransferPhase
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public let attempt: Int
    public let sequence: UInt64

    public init(
        phase: RemoteTransferPhase,
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        attempt: Int = 0,
        sequence: UInt64 = 0
    ) {
        self.phase = phase
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = totalBytes.map { max(0, $0) }
        self.attempt = max(0, attempt)
        self.sequence = sequence
    }

    private enum CodingKeys: String, CodingKey { case phase, completedBytes, totalBytes, attempt, sequence }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(phase: try c.decode(RemoteTransferPhase.self, forKey: .phase),
                  completedBytes: try c.decode(Int64.self, forKey: .completedBytes),
                  totalBytes: try c.decodeIfPresent(Int64.self, forKey: .totalBytes),
                  attempt: try c.decode(Int.self, forKey: .attempt),
                  sequence: try c.decode(UInt64.self, forKey: .sequence))
    }
}

/// Snapshot of a coordinator task. It is authoritative for the terminal state;
/// event streams are only an observation convenience.
public struct RemoteTransferSnapshot: Sendable, Hashable, Codable {
    public let id: UUID
    public let phase: RemoteTransferPhase
    public let progress: RemoteTransferProgress?
    public let errorDescription: String?
    public let materializedFileURL: URL?

    public init(
        id: UUID,
        phase: RemoteTransferPhase,
        progress: RemoteTransferProgress? = nil,
        errorDescription: String? = nil,
        materializedFileURL: URL? = nil
    ) {
        self.id = id
        self.phase = phase
        self.progress = progress
        self.errorDescription = errorDescription
        self.materializedFileURL = materializedFileURL
    }

    public var isTerminal: Bool {
        switch phase {
        case .completed, .cancelled, .failed:
            return true
        case .preparing, .transferring, .verifying, .committing, .needsAuthorization, .reconciling:
            return false
        }
    }
}
