import Combine
import Foundation
import SwiftUI

enum RecentChangesState: Equatable, Sendable {
    case loading
    case availableWithChanges
    case availableEmpty
    case journalUnavailable
    case journalCapacityUnavailable
    case incompleteEvidence
}

struct RecentChangeRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let summary: String
    let observedAt: Date
    let timeText: String
    let timeQualityText: String
    let sourceText: String
    let subjectText: String
    let identityQualityText: String
    let statusText: String
    let isSupplemental: Bool
}

struct RecentChangeDetail: Identifiable, Equatable, Sendable {
    let id: UUID
    let row: RecentChangeRow
    let fields: [RecentChangeField]
    let availabilityText: String?
    let supplementalLimitation: String?
}

struct RecentChangeField: Identifiable, Equatable, Sendable {
    let label: String
    let value: String

    var id: String {
        label
    }
}

@MainActor
// swiftlint:disable:next type_body_length
final class RecentChangesViewModel: ObservableObject {
    static let maximumRows = 200

    @Published private(set) var state: RecentChangesState = .loading
    @Published private(set) var rows: [RecentChangeRow] = []
    @Published private(set) var coverageWarning: String?
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var capacityRecoveryMessage: String?

    let journal: any EvidenceJournal
    private var detailsByID: [UUID: RecentChangeDetail] = [:]

    init(journal: any EvidenceJournal) {
        self.journal = journal
    }

    func refresh() async {
        if let deferred = journal as? DeferredEvidenceJournal,
           !(await deferred.isResolved()) {
            state = .loading
            rows = []
            detailsByID = [:]
            coverageWarning = nil
            return
        }

        let status = await journal.retentionStatus()
        switch status.availability {
        case .unavailable:
            state = .journalUnavailable
            rows = []
            detailsByID = [:]
            coverageWarning = nil
            lastRefreshDate = Date()
            return
        case .capacityUnavailable:
            state = .journalCapacityUnavailable
            rows = []
            detailsByID = [:]
            coverageWarning = nil
            lastRefreshDate = Date()
            return
        case .available:
            break
        }

        let observations = await journal.query(
            EvidenceJournalQuery(limit: Self.maximumRows, newestFirst: true)
        )
        let sourceHealth = await journal.sourceHealth()
        let mappedDetails = observations
            .filter(IncidentChangeProjection.isUserVisibleChange)
            .map(Self.detail(for:))
        detailsByID = Dictionary(uniqueKeysWithValues: mappedDetails.map { ($0.id, $0) })
        rows = mappedDetails.map(\.row)
        let incomplete = sourceHealth.contains { record in
            record.reason == .incompleteCapture
                || record.event == .reconciliationFailure
                || record.event == .sourceUnavailable
        }
        coverageWarning = incomplete ? "Some changes may be missing." : nil
        if incomplete {
            state = .incompleteEvidence
        } else if rows.isEmpty {
            state = .availableEmpty
        } else {
            state = .availableWithChanges
        }
        lastRefreshDate = Date()
    }

    func detail(for id: UUID) -> RecentChangeDetail? {
        detailsByID[id]
    }

    func recoverCapacity() async {
        do {
            let result = try await journal.clearUnprotectedHistory()
            await refresh()
            capacityRecoveryMessage = result.observationsDeleted == 0
                ? "No unprotected observations were available to remove. Capture remains unavailable " +
                "because protected or non-observation journal data still fills the bound."
                : "Removed \(result.observationsDeleted) unprotected observations. Protected captures " +
                "were preserved, and capture is available again if the journal reports available."
        } catch {
            capacityRecoveryMessage = "Safe evidence recovery could not complete. Existing history has " +
                "not been reported as lost."
        }
    }

    func dismissCapacityRecoveryMessage() {
        capacityRecoveryMessage = nil
    }

    private static func detail(for observation: Observation) -> RecentChangeDetail {
        let supplemental = observation.sourceID == .network
        let row = RecentChangeRow(
            id: observation.id,
            title: title(for: observation),
            summary: summary(for: observation),
            observedAt: observation.time.observedWallTime,
            timeText: DateFormatter.recentChanges.string(from: observation.time.observedWallTime),
            timeQualityText: timeQualityText(for: observation.time.sourceTimestampQuality),
            sourceText: sourceText(for: observation),
            subjectText: subjectText(for: observation.subject),
            identityQualityText: identityQualityText(for: observation.subject.quality),
            statusText: "Observed",
            isSupplemental: supplemental
        )
        var fields = [
            RecentChangeField(label: "Source", value: row.sourceText),
            RecentChangeField(label: "Subject", value: row.subjectText),
            RecentChangeField(label: "Identity quality", value: row.identityQualityText),
            RecentChangeField(label: "Change", value: changeText(for: observation))
        ]
        if let attributesText = approvedAttributesText(for: observation) {
            fields.append(RecentChangeField(label: "Attributes", value: attributesText))
        }
        let availabilityText = availabilityText(for: observation.availability)
        let limitation = supplemental
            ? "Supplemental network evidence describes path and interface facts; it does not identify " +
            "hardware, router, or service failure."
            : nil
        return RecentChangeDetail(
            id: observation.id,
            row: row,
            fields: fields,
            availabilityText: availabilityText,
            supplementalLimitation: limitation
        )
    }

    private static func title(for observation: Observation) -> String {
        switch observation.eventKind {
        case .storageDiskLifecycle:
            return storageDiskTitle(for: observation)
        case .storageMountLifecycle:
            return storageMountTitle(for: observation)
        case .powerSourceTransition:
            return powerTitle(for: observation)
        case .networkPathTransition:
            return networkTitle(for: observation)
        case .sleepWakeBoundary, .sourceUnavailable, .sourceSuppressed, .unknown:
            return "Observed change"
        }
    }

    private static func storageDiskTitle(for observation: Observation) -> String {
        switch lifecycleWord(for: observation) {
        case "appeared": return "Storage device connected"
        case "disappeared": return "Storage device disconnected"
        default: return "Storage device changed"
        }
    }

    private static func storageMountTitle(for observation: Observation) -> String {
        switch lifecycleWord(for: observation) {
        case "mounted": return "Volume became available"
        case "unmounted": return "Volume became unavailable"
        default: return "Mounted volume changed"
        }
    }

    private static func powerTitle(for observation: Observation) -> String {
        guard let previous = sourceState(from: observation.previousState),
              let current = sourceState(from: observation.currentState),
              previous != current
        else {
            return "Charging state changed"
        }
        return "Power source changed from \(powerLabel(previous)) to \(powerLabel(current))"
    }

    private static func networkTitle(for observation: Observation) -> String {
        switch statusState(from: observation.currentState) {
        case "SATISFIED": return "Network path became available"
        case "UNSATISFIED", "REQUIRES_CONNECTION": return "Network path became unavailable"
        default: return "Network interface availability changed"
        }
    }

    private static func summary(for observation: Observation) -> String {
        switch observation.eventKind {
        case .storageDiskLifecycle:
            return "A disk-level storage transition was observed after the startup baseline."
        case .storageMountLifecycle:
            return "A mounted-volume transition was observed after the startup baseline."
        case .powerSourceTransition:
            return "Small Matter observed a direct power-state transition."
        case .networkPathTransition:
            return "Small Matter observed a supplemental network path change."
        default:
            return "Small Matter observed a change; additional detail may be unavailable."
        }
    }

    private static func changeText(for observation: Observation) -> String {
        switch observation.eventKind {
        case .powerSourceTransition:
            if let previous = sourceState(from: observation.previousState),
               let current = sourceState(from: observation.currentState) {
                return "\(powerLabel(previous)) → \(powerLabel(current))"
            }
            if let previous = boolState(from: observation.previousState, key: "charging"),
               let current = boolState(from: observation.currentState, key: "charging") {
                return "Charging \(previous ? "on" : "off") → \(current ? "on" : "off")"
            }
        case .networkPathTransition:
            let previous = statusState(from: observation.previousState).map(networkStatusLabel) ?? "Unknown"
            let current = statusState(from: observation.currentState).map(networkStatusLabel) ?? "Unknown"
            return "\(previous) → \(current)"
        default:
            break
        }
        return lifecycleWord(for: observation).capitalized
    }

    private static func lifecycleWord(for observation: Observation) -> String {
        guard let lifecycle = stringValue(in: observation.attributes, key: "lifecycle") else {
            return "changed"
        }
        switch lifecycle {
        case "diskAppeared": return "appeared"
        case "diskDisappeared": return "disappeared"
        case "volumeMounted": return "mounted"
        case "volumeUnmounted": return "unmounted"
        default: return "changed"
        }
    }

    private static func sourceText(for observation: Observation) -> String {
        switch observation.sourceID {
        case .storage:
            return observation.eventKind == .storageMountLifecycle ? "NSWorkspace" : "Disk Arbitration"
        case .power: return "IOPowerSources"
        case .network: return "Network.framework / NWPathMonitor"
        default: return "Evidence source"
        }
    }

    private static func subjectText(for subject: EvidenceSubject) -> String {
        if let safeDisplayLabel = subject.safeDisplayLabel, !safeDisplayLabel.isEmpty {
            return safeDisplayLabel
        }
        switch subject.type {
        case .storageDisk: return "Storage disk"
        case .mountedVolume: return "Mounted volume"
        case .networkInterface: return "Network path"
        case .powerSource: return "Direct power source"
        default: return "Subject unavailable"
        }
    }

    private static func identityQualityText(for quality: EvidenceIdentityQuality) -> String {
        switch quality {
        case .provenStable: return "Qualified stable identity"
        case .qualified: return "Qualified"
        case .transientRunLocal: return "Run-local"
        case .weak: return "Weak"
        case .unavailable: return "Unavailable"
        case .unknown: return "Unknown"
        }
    }

    private static func timeQualityText(for quality: EvidenceTimestampQuality) -> String {
        switch quality {
        case .exact: return "Exact"
        case .estimated: return "Estimated"
        case .unavailable: return "Unavailable"
        case .unknown: return "Unknown"
        }
    }

    private static func availabilityText(for availability: EvidenceAvailability) -> String? {
        switch availability {
        case .available: return nil
        case let .unavailable(reason): return "Evidence unavailable: \(unknownReasonText(reason))"
        case let .unknown(reason): return "Evidence unknown: \(unknownReasonText(reason))"
        }
    }

    private static func unknownReasonText(_ reason: EvidenceUnknownReason) -> String {
        switch reason {
        case .identityUnavailable: return "identity unavailable"
        case .clockUnavailable: return "source time unavailable"
        case .sourceUnavailable: return "source unavailable"
        case .permissionOrAPIUnavailable: return "permission or API unavailable"
        case .notObserved: return "not observed"
        case .redacted: return "redacted"
        case .incompleteCapture: return "incomplete capture"
        case .journalCapacityUnavailable: return "local evidence storage is full"
        default: return "additional detail unavailable"
        }
    }

    private static func approvedAttributesText(for observation: Observation) -> String? {
        var values: [String] = []
        if let lifecycle = stringValue(in: observation.attributes, key: "lifecycle") {
            values.append("Lifecycle: \(lifecycleLabel(lifecycle))")
        }
        if let quality = stringValue(in: observation.attributes, key: "identityQuality") {
            values.append("Identity: \(qualityLabel(quality))")
        }
        if let wholeDisk = boolValue(in: observation.attributes, key: "isWholeDisk") {
            values.append(wholeDisk ? "Whole disk fact" : "Mounted-volume fact")
        }
        if let interfaceTypes = stringArrayValue(in: observation.attributes, key: "interfaceTypes"),
           !interfaceTypes.isEmpty {
            values.append("Interface: \(interfaceTypes.map(interfaceLabel).joined(separator: ", "))")
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private static func stringValue(in values: [String: EvidenceValue], key: String) -> String? {
        guard let value = values[key], case let .string(string) = value else { return nil }
        return string
    }

    private static func boolValue(in values: [String: EvidenceValue], key: String) -> Bool? {
        guard let value = values[key], case let .boolean(boolean) = value else { return nil }
        return boolean
    }

    private static func stringArrayValue(in values: [String: EvidenceValue], key: String) -> [String]? {
        guard let value = values[key], case let .array(items) = value else { return nil }
        return items.compactMap { item in
            guard case let .string(string) = item else { return nil }
            return string
        }
    }

    private static func objectValue(_ value: EvidenceValue?, key: String) -> EvidenceValue? {
        guard let value, case let .object(object) = value else { return nil }
        return object[key]
    }

    private static func sourceState(from value: EvidenceValue?) -> String? {
        guard let value = objectValue(value, key: "source"), case let .string(source) = value else { return nil }
        return source
    }

    private static func boolState(from value: EvidenceValue?, key: String) -> Bool? {
        guard let value = objectValue(value, key: key), case let .boolean(boolean) = value else { return nil }
        return boolean
    }

    private static func statusState(from value: EvidenceValue?) -> String? {
        guard let value = objectValue(value, key: "status"), case let .string(status) = value else { return nil }
        return status
    }

    private static func powerLabel(_ value: String) -> String {
        switch value {
        case "AC": return "AC"
        case "BATTERY": return "Battery"
        default: return "Unknown"
        }
    }

    private static func networkStatusLabel(_ value: String) -> String {
        switch value {
        case "SATISFIED": return "Available"
        case "UNSATISFIED", "REQUIRES_CONNECTION": return "Unavailable"
        default: return "Unknown"
        }
    }

    private static func lifecycleLabel(_ value: String) -> String {
        switch value {
        case "diskAppeared": return "Disk appeared"
        case "diskDisappeared": return "Disk disappeared"
        case "volumeMounted": return "Volume mounted"
        case "volumeUnmounted": return "Volume unmounted"
        default: return "Observed"
        }
    }

    private static func qualityLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
    }

    private static func interfaceLabel(_ value: String) -> String {
        switch value {
        case "WIFI": return "Wi-Fi"
        case "WIRED_ETHERNET": return "Wired Ethernet"
        case "CELLULAR": return "Cellular"
        case "LOOPBACK": return "Loopback"
        default: return "Other"
        }
    }
} // swiftlint:disable:this file_length
