import Foundation

enum IncidentCaptureStatus: String, Codable, Equatable, Sendable {
    case complete = "COMPLETE"
    case incomplete = "INCOMPLETE"
}

struct IncidentMarker: Codable, Equatable, Sendable {
    let markerID: UUID
    let observationID: UUID?
    let wallTime: Date
    let continuousNanoseconds: UInt64?
    let localSequence: UInt64?

    init(
        markerID: UUID = UUID(),
        wallTime: Date,
        continuousNanoseconds: UInt64? = nil,
        localSequence: UInt64? = nil,
        observationID: UUID? = nil
    ) {
        self.markerID = markerID
        self.observationID = observationID
        self.wallTime = wallTime
        self.continuousNanoseconds = continuousNanoseconds
        self.localSequence = localSequence
    }

    /// Compatibility initializer for the pre-I5 observation-anchored marker.
    init(observationID: UUID, wallTime: Date, localSequence: UInt64) {
        self.init(
            markerID: observationID,
            wallTime: wallTime,
            localSequence: localSequence,
            observationID: observationID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case markerID
        case observationID
        case wallTime
        case continuousNanoseconds
        case localSequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let observationID = try container.decodeIfPresent(UUID.self, forKey: .observationID)
        markerID = try container.decodeIfPresent(UUID.self, forKey: .markerID) ?? observationID ?? UUID()
        self.observationID = observationID
        wallTime = try container.decode(Date.self, forKey: .wallTime)
        continuousNanoseconds = try container.decodeIfPresent(UInt64.self, forKey: .continuousNanoseconds)
        localSequence = try container.decodeIfPresent(UInt64.self, forKey: .localSequence)
    }
}

struct IncidentCaptureSession: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let marker: IncidentMarker
    let preWindowSeconds: Int
    let postWindowSeconds: Int
    let startedAt: Date
    let processRunID: UUID
    let materializedContext: EvidenceValue
    let observationIDs: [UUID]
    let unknowns: [EvidenceMissing]
    let schemaVersion: Int

    init(
        id: UUID,
        marker: IncidentMarker,
        startedAt: Date,
        processRunID: UUID,
        materializedContext: EvidenceValue,
        observationIDs: [UUID] = [],
        unknowns: [EvidenceMissing] = [],
        schemaVersion: Int = Horizon2EvidenceConfiguration.incidentPackageSchemaVersion
    ) {
        self.id = id
        self.marker = marker
        preWindowSeconds = Horizon2EvidenceConfiguration.incidentPreWindowSeconds
        postWindowSeconds = Horizon2EvidenceConfiguration.incidentPostWindowSeconds
        self.startedAt = startedAt
        self.processRunID = processRunID
        self.materializedContext = materializedContext
        self.observationIDs = observationIDs
        self.unknowns = unknowns
        self.schemaVersion = schemaVersion
    }
}

struct IncidentPackage: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let marker: IncidentMarker
    let preWindowSeconds: Int
    let postWindowSeconds: Int
    let status: IncidentCaptureStatus
    let schemaVersion: Int
    let completedAt: Date?
    let materializedContext: EvidenceValue
    let observationIDs: [UUID]
    let unknowns: [EvidenceMissing]
    let failureReason: EvidenceUnknownReason?

    init(
        id: UUID,
        marker: IncidentMarker,
        status: IncidentCaptureStatus,
        schemaVersion: Int = Horizon2EvidenceConfiguration.incidentPackageSchemaVersion,
        completedAt: Date?,
        materializedContext: EvidenceValue,
        observationIDs: [UUID],
        unknowns: [EvidenceMissing] = [],
        failureReason: EvidenceUnknownReason? = nil
    ) {
        self.id = id
        self.marker = marker
        preWindowSeconds = Horizon2EvidenceConfiguration.incidentPreWindowSeconds
        postWindowSeconds = Horizon2EvidenceConfiguration.incidentPostWindowSeconds
        self.status = status
        self.schemaVersion = schemaVersion
        self.completedAt = completedAt
        self.materializedContext = materializedContext
        self.observationIDs = observationIDs
        self.unknowns = unknowns
        self.failureReason = failureReason
    }
}
