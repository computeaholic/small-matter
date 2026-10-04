import Foundation

enum StorageRawSemanticRole: String, Codable, Equatable, Sendable {
    case baseline = "BASELINE"
    case transition = "TRANSITION"
    case confirmation = "CONFIRMATION"
    case uncertain = "UNCERTAIN"
}

enum StorageInventoryFailure: String, Equatable, Sendable {
    case ioRegistryUnavailable
    case diskArbitrationUnavailable
    case mountedVolumeUnavailable
    case partialInventory
    case malformedPropertyList

    var detail: String {
        switch self {
        case .ioRegistryUnavailable: return "IOKit block-media inventory was unavailable"
        case .diskArbitrationUnavailable: return "Disk Arbitration could not normalize the storage inventory"
        case .mountedVolumeUnavailable: return "mounted-volume inventory was unavailable"
        case .partialInventory: return "native storage inventory was only partially available"
        case .malformedPropertyList: return "the storage fixture contained malformed property-list data"
        }
    }
}

struct StorageInventoryMetrics: Equatable, Sendable {
    let snapshotDurationNanoseconds: UInt64?
    let diskCount: Int
    let mountedVolumeCount: Int
    let performedOnMainThread: Bool

    static let unavailable = StorageInventoryMetrics(
        snapshotDurationNanoseconds: nil,
        diskCount: 0,
        mountedVolumeCount: 0,
        performedOnMainThread: false
    )
}

struct StorageInventorySnapshot: Sendable {
    let events: [StorageRawEvent]
    let failure: StorageInventoryFailure?
    let metrics: StorageInventoryMetrics

    static func available(
        _ events: [StorageRawEvent],
        metrics: StorageInventoryMetrics = .unavailable
    ) -> StorageInventorySnapshot {
        StorageInventorySnapshot(events: events, failure: nil, metrics: metrics)
    }

    static func unavailable(
        _ failure: StorageInventoryFailure,
        events: [StorageRawEvent] = [],
        metrics: StorageInventoryMetrics = .unavailable
    ) -> StorageInventorySnapshot {
        StorageInventorySnapshot(events: events, failure: failure, metrics: metrics)
    }
}

enum StorageEntityClass: String, Hashable, Sendable {
    case disk
    case volume
}

struct StorageEntityKey: Hashable, Sendable {
    let entityClass: StorageEntityClass
    let identifier: String
}

struct StorageRawEvent: Equatable, Sendable {
    let kind: StorageRawEventKind
    let identity: StorageRawIdentity
    let occurrence: EvidenceSourceOccurrence
    let callbackToken: String?
    let semanticRole: StorageRawSemanticRole

    init(
        kind: StorageRawEventKind,
        identity: StorageRawIdentity,
        occurrence: EvidenceSourceOccurrence,
        callbackToken: String?,
        semanticRole: StorageRawSemanticRole = .transition
    ) {
        self.kind = kind
        self.identity = identity
        self.occurrence = occurrence
        self.callbackToken = callbackToken
        self.semanticRole = semanticRole
    }
}

extension StorageRawEvent {
    var entityClass: StorageEntityClass {
        switch kind {
        case .diskAppeared, .diskDisappeared: return .disk
        case .volumeMounted, .volumeUnmounted: return .volume
        }
    }

    var state: StorageEntityState {
        switch kind {
        case .diskAppeared: return .present
        case .diskDisappeared: return .absent
        case .volumeMounted: return .mounted
        case .volumeUnmounted: return .unmounted
        }
    }

    func assigningSemanticRole(_ role: StorageRawSemanticRole) -> StorageRawEvent {
        StorageRawEvent(
            kind: kind,
            identity: identity,
            occurrence: occurrence,
            callbackToken: callbackToken,
            semanticRole: role
        )
    }
}

enum StorageEntityState: String, Sendable {
    case absent
    case present
    case unmounted
    case mounted
}

struct StorageStateMachine: Sendable {
    private let maximumEntries: Int
    private var states: [StorageEntityKey: StorageEntityState] = [:]
    private var baselineStates: [StorageEntityKey: StorageEntityState] = [:]
    private var stateOrder: [StorageEntityKey] = []

    init(
        baseline: [StorageRawEvent] = [],
        maximumEntries: Int = 512
    ) {
        self.maximumEntries = max(1, maximumEntries)
        for event in baseline {
            guard let key = Self.key(for: event) else { continue }
            states[key] = event.state
            baselineStates[key] = event.state
            stateOrder.append(key)
        }
        trimIfNeeded()
    }

    mutating func classify(_ raw: StorageRawEvent) -> StorageRawSemanticRole {
        guard let key = Self.key(for: raw) else { return .uncertain }

        let role: StorageRawSemanticRole
        if let previous = states[key] {
            if previous == raw.state {
                role = baselineStates[key] == raw.state ? .baseline : .confirmation
            } else {
                role = .transition
            }
        } else {
            role = .transition
        }

        states[key] = raw.state
        if !stateOrder.contains(key) {
            stateOrder.append(key)
        }
        trimIfNeeded()
        return role
    }

    @discardableResult
    mutating func establishBaseline(from raw: StorageRawEvent) -> Bool {
        guard let key = Self.key(for: raw) else { return false }
        states[key] = raw.state
        baselineStates[key] = raw.state
        if !stateOrder.contains(key) {
            stateOrder.append(key)
        }
        trimIfNeeded()
        return true
    }

    var currentInventoryForTesting: [StorageEntityKey: StorageEntityState] {
        states
    }

    private mutating func trimIfNeeded() {
        while stateOrder.count > maximumEntries {
            let retired = stateOrder.removeFirst()
            states.removeValue(forKey: retired)
            baselineStates.removeValue(forKey: retired)
        }
    }

    private static func key(for raw: StorageRawEvent) -> StorageEntityKey? {
        guard let identifier = raw.identity.stateIdentifier(for: raw.entityClass) else { return nil }
        return StorageEntityKey(entityClass: raw.entityClass, identifier: identifier)
    }
}

extension StorageRawIdentity {
    var stateIdentifier: String? {
        stateIdentifier(for: .disk)
    }

    func stateIdentifier(for entityClass: StorageEntityClass) -> String? {
        // swiftlint:disable trailing_comma
        let candidates: [(String, String?)]
        switch entityClass {
        case .disk:
            candidates = [
                ("media", mediaUUID),
                ("hardware", hardwareUUID),
                ("serial", serialNumber),
                ("bsd", bsdName),
                ("path", filesystemPath),
                ("volume", volumeName),
            ]
        case .volume:
            // NSWorkspace mount notifications expose the mounted path and do
            // not carry the UUIDs available in the native inventory snapshot.
            candidates = [
                ("path", filesystemPath),
                ("volume", volumeName),
                ("media", mediaUUID),
                ("hardware", hardwareUUID),
                ("serial", serialNumber),
                ("bsd", bsdName),
            ]
        }
        // swiftlint:enable trailing_comma

        for (prefix, value) in candidates {
            if let value, !value.isEmpty {
                return "\(prefix):\(value)"
            }
        }
        return nil
    }
}
