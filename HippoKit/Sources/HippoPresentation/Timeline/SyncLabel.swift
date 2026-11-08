import LocalRepository

/// What the user sees for a capture's sync state.
public enum SyncLabel: Sendable, Equatable {
    case onIPhone, synced, needsAttention

    public init(_ b: SyncBucket) {
        switch b {
        case .notSynced: self = .onIPhone
        case .synced: self = .synced
        case .needsAttention: self = .needsAttention
        }
    }

    public var title: String {
        switch self {
        case .onIPhone: "On iPhone"
        case .synced: "Synced"
        case .needsAttention: "Needs attention"
        }
    }
}
