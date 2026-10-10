import Combine
import Foundation

enum IncidentCaptureState: Equatable, Sendable {
    case idle
    case starting
    case capturing
    case finalizing
    case complete
    case incomplete
    case unavailable
    case failure
}

struct IncidentContextSnapshot: Codable, Equatable, Sendable {
    let capturedAt: Date
    let values: EvidenceValue
    let unknowns: [EvidenceMissing]

    init(capturedAt: Date, values: EvidenceValue, unknowns: [EvidenceMissing] = []) {
        self.capturedAt = capturedAt
        self.values = values
        self.unknowns = unknowns
    }

    @MainActor
    // Why: explicit fail-closed matrix.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func current(
        capturedAt: Date,
        systemStats: SystemStatsModel,
        battery: BatteryManager,
        cooling: CoolingService
    ) -> IncidentContextSnapshot {
        var unknowns: [EvidenceMissing] = []
        var system: [String: EvidenceValue] = [:]
        let telemetry = systemStats.telemetrySnapshot

        if telemetry.cpu.freshness == .unavailable {
            unknowns.append(EvidenceMissing(
                sourceID: nil,
                reason: .sourceUnavailable,
                explanation: "CPU context was unavailable at the marker."
            ))
        } else {
            system["cpuUtilizationPercent"] = .decimal(String(format: "%.2f", telemetry.cpu.totalUtilization))
        }

        if telemetry.memory.freshness == .unavailable {
            unknowns.append(EvidenceMissing(
                sourceID: nil,
                reason: .sourceUnavailable,
                explanation: "Memory context was unavailable at the marker."
            ))
        } else {
            system["memoryPressure"] = .string(telemetry.memory.telemetry.pressure.rawValue)
            system["memoryUsedBytes"] = .unsigned(telemetry.memory.telemetry.usedBytes)
            system["memoryPhysicalBytes"] = .unsigned(telemetry.memory.telemetry.physicalBytes)
            if let swap = telemetry.memory.telemetry.swapUsedBytes {
                system["swapUsedBytes"] = .unsigned(swap)
            }
        }

        if telemetry.storage.freshness != .unavailable {
            if let free = telemetry.storage.freeBytes {
                system["rootStorageFreeBytes"] = .unsigned(free)
            }
            if let total = telemetry.storage.totalBytes {
                system["rootStorageTotalBytes"] = .unsigned(total)
            }
        } else {
            unknowns.append(EvidenceMissing(
                sourceID: nil,
                reason: .sourceUnavailable,
                explanation: "Root storage context was unavailable at the marker."
            ))
        }

        var network: [String: EvidenceValue] = [:]
        if telemetry.network.freshness == .unavailable {
            unknowns.append(EvidenceMissing(
                sourceID: .network,
                reason: .sourceUnavailable,
                explanation: "Network context was unavailable at the marker."
            ))
        } else {
            if let sent = telemetry.network.sentBytes {
                network["sentBytes"] = .unsigned(sent)
            }
            if let received = telemetry.network.receivedBytes {
                network["receivedBytes"] = .unsigned(received)
            }
            if let upload = telemetry.network.uploadBytesPerSecond {
                network["uploadBytesPerSecond"] = .decimal(String(format: "%.2f", upload))
            }
            if let download = telemetry.network.downloadBytesPerSecond {
                network["downloadBytesPerSecond"] = .decimal(String(format: "%.2f", download))
            }
        }

        system["lowPowerMode"] = .boolean(telemetry.thermal.lowPowerMode)
        system["thermalState"] = .string(telemetry.thermal.thermalState.contextLabel)

        var batteryValues: [String: EvidenceValue] = [
            "present": .boolean(battery.snapshot.present),
            "acConnected": .boolean(battery.snapshot.isACConnected),
            "charging": .boolean(battery.snapshot.isCharging)
        ]
        if let charge = battery.snapshot.stateOfChargePercent {
            batteryValues["stateOfChargePercent"] = .decimal(String(format: "%.2f", charge))
        }
        if battery.snapshot.availability == .unavailable {
            unknowns.append(EvidenceMissing(
                sourceID: .power,
                reason: .sourceUnavailable,
                explanation: "Battery context was unavailable at the marker."
            ))
        }

        var coolingValues: [String: EvidenceValue] = [:]
        if let fan = cooling.snapshot.fans.first {
            coolingValues["primaryFanRPM"] = .integer(Int64(fan.currentRPM))
        }
        if let temperature = cooling.snapshot.primaryTemperature {
            coolingValues["primaryTemperatureCelsius"] = .decimal(String(format: "%.2f", temperature.valueCelsius))
        }
        if cooling.snapshot.freshness == .unavailable {
            unknowns.append(EvidenceMissing(
                sourceID: nil,
                reason: .sourceUnavailable,
                explanation: "Cooling context was unavailable at the marker."
            ))
        }

        return IncidentContextSnapshot(
            capturedAt: capturedAt,
            values: .object([
                "system": .object(system),
                "network": .object(network),
                "battery": .object(batteryValues),
                "cooling": .object(coolingValues)
            ]),
            unknowns: unknowns
        )
    }
}

enum IncidentWindowCoverage: String, Equatable, Sendable {
    case complete = "COMPLETE"
    case partial = "PARTIAL"
    case unavailable = "UNAVAILABLE"
}

struct IncidentWindowMetric: Equatable, Sendable {
    let sampleCount: Int
    let minimum: Double
    let maximum: Double
    let mean: Double

    var evidenceValue: EvidenceValue {
        .object([
            "sampleCount": .unsigned(UInt64(sampleCount)),
            "minimum": .decimal(Self.decimal(minimum)),
            "maximum": .decimal(Self.decimal(maximum)),
            "mean": .decimal(Self.decimal(mean))
        ])
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct IncidentWindowSummary: Equatable, Sendable {
    let requestedStart: Date
    let requestedEnd: Date
    let coveredStart: Date?
    let coveredEnd: Date?
    let sampleCount: Int
    let coverage: IncidentWindowCoverage
    let metrics: [String: IncidentWindowMetric]
    let states: [String: [String]]

    var evidenceValue: EvidenceValue {
        var fields: [String: EvidenceValue] = [
            "requestedStart": .date(requestedStart),
            "requestedEnd": .date(requestedEnd),
            "coveredStart": coveredStart.map(EvidenceValue.date) ?? .null,
            "coveredEnd": coveredEnd.map(EvidenceValue.date) ?? .null,
            "sampleCount": .unsigned(UInt64(sampleCount)),
            "coverage": .string(coverage.rawValue)
        ]
        for key in metrics.keys.sorted() {
            let metric = metrics[key]!
            fields["metric_\(key)_sampleCount"] = .unsigned(UInt64(metric.sampleCount))
            fields["metric_\(key)_minimum"] = .decimal(String(format: "%.2f", metric.minimum))
            fields["metric_\(key)_maximum"] = .decimal(String(format: "%.2f", metric.maximum))
            fields["metric_\(key)_mean"] = .decimal(String(format: "%.2f", metric.mean))
        }
        for key in states.keys.sorted() {
            fields["state_\(key)"] = .string(states[key]!.joined(separator: " | "))
        }
        return .object(fields)
    }
}

private struct IncidentContextSample: Equatable, Sendable {
    let timestamp: Date
    let values: EvidenceValue
}

/// One in-memory, bounded projection of the telemetry already collected by the
/// product. It deliberately stores a compact scalar snapshot rather than a
/// second polling stream or a durable high-frequency series.
final class IncidentContextHistory: ObservableObject {
    static let rollingWindow: TimeInterval = 5 * 60
    static let maximumSamples = 360

    private var samples: [IncidentContextSample] = []

    var sampleCount: Int {
        samples.count
    }

    @MainActor
    func append(
        timestamp: Date,
        systemStats: SystemStatsModel,
        battery: BatteryManager,
        cooling: CoolingService
    ) {
        append(IncidentContextSnapshot.current(
            capturedAt: timestamp,
            systemStats: systemStats,
            battery: battery,
            cooling: cooling
        ))
    }

    func append(_ snapshot: IncidentContextSnapshot) {
        guard samples.last?.timestamp != snapshot.capturedAt else { return }
        samples.append(IncidentContextSample(timestamp: snapshot.capturedAt, values: snapshot.values))
        trim(through: snapshot.capturedAt)
    }

    func summary(marker: Date, preWindow: TimeInterval, postWindow: TimeInterval) -> IncidentWindowSummary {
        let start = marker.addingTimeInterval(-preWindow)
        let end = marker.addingTimeInterval(postWindow)
        let selected = samples.filter { $0.timestamp >= start && $0.timestamp <= end }
        let coveredStart = selected.first?.timestamp
        let coveredEnd = selected.last?.timestamp
        let coverage: IncidentWindowCoverage
        if selected.isEmpty {
            coverage = .unavailable
        } else if selected.first!.timestamp <= start && selected.last!.timestamp >= end {
            coverage = .complete
        } else {
            coverage = .partial
        }
        let metrics = Self.metrics(from: selected)
        let states = Self.states(from: selected)
        return IncidentWindowSummary(
            requestedStart: start,
            requestedEnd: end,
            coveredStart: coveredStart,
            coveredEnd: coveredEnd,
            sampleCount: selected.count,
            coverage: coverage,
            metrics: metrics,
            states: states
        )
    }

    private func trim(through timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(-Self.rollingWindow)
        samples.removeAll { $0.timestamp < cutoff }
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }

    private static let metricPaths: [(String, [String])] = [
        ("cpuUtilizationPercent", ["system", "cpuUtilizationPercent"]),
        ("memoryUsedBytes", ["system", "memoryUsedBytes"]),
        ("memoryPhysicalBytes", ["system", "memoryPhysicalBytes"]),
        ("swapUsedBytes", ["system", "swapUsedBytes"]),
        ("rootStorageFreeBytes", ["system", "rootStorageFreeBytes"]),
        ("rootStorageTotalBytes", ["system", "rootStorageTotalBytes"]),
        ("networkSentBytes", ["network", "sentBytes"]),
        ("networkReceivedBytes", ["network", "receivedBytes"]),
        ("networkUploadBytesPerSecond", ["network", "uploadBytesPerSecond"]),
        ("networkDownloadBytesPerSecond", ["network", "downloadBytesPerSecond"]),
        ("stateOfChargePercent", ["battery", "stateOfChargePercent"]),
        ("primaryFanRPM", ["cooling", "primaryFanRPM"]),
        ("primaryTemperatureCelsius", ["cooling", "primaryTemperatureCelsius"])
    ]

    private static let statePaths: [(String, [String])] = [
        ("memoryPressure", ["system", "memoryPressure"]),
        ("thermalState", ["system", "thermalState"]),
        ("lowPowerMode", ["system", "lowPowerMode"]),
        ("batteryPresent", ["battery", "present"]),
        ("batteryACConnected", ["battery", "acConnected"]),
        ("batteryCharging", ["battery", "charging"])
    ]

    private static func metrics(from samples: [IncidentContextSample]) -> [String: IncidentWindowMetric] {
        var result: [String: IncidentWindowMetric] = [:]
        for (name, path) in metricPaths {
            let values = samples.compactMap { numericValue(at: path, in: $0.values) }
            guard !values.isEmpty else { continue }
            result[name] = IncidentWindowMetric(
                sampleCount: values.count,
                minimum: values.min()!,
                maximum: values.max()!,
                mean: values.reduce(0, +) / Double(values.count)
            )
        }
        return result
    }

    private static func states(from samples: [IncidentContextSample]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (name, path) in statePaths {
            let values = samples.compactMap { scalarDescription(at: path, in: $0.values) }
            let distinct = Array(Set(values)).sorted()
            if !distinct.isEmpty {
                result[name] = distinct
            }
        }
        return result
    }

    private static func value(at path: [String], in root: EvidenceValue) -> EvidenceValue? {
        guard let first = path.first, case let .object(fields) = root,
              let fieldValue = fields[first] else { return nil }
        if path.count == 1 {
            return fieldValue
        }
        return value(at: Array(path.dropFirst()), in: fieldValue)
    }

    private static func numericValue(at path: [String], in root: EvidenceValue) -> Double? {
        guard let value = value(at: path, in: root) else { return nil }
        switch value {
        case let .decimal(value): return Double(value)
        case let .integer(value): return Double(value)
        case let .unsigned(value): return Double(value)
        default: return nil
        }
    }

    private static func scalarDescription(at path: [String], in root: EvidenceValue) -> String? {
        guard let value = value(at: path, in: root) else { return nil }
        switch value {
        case let .string(value): return value
        case let .boolean(value): return value ? "true" : "false"
        default: return nil
        }
    }
}

protocol IncidentCaptureScheduledTask: AnyObject, Sendable {
    func cancel()
}

protocol IncidentCaptureScheduler: AnyObject, Sendable {
    @discardableResult
    func schedule(after interval: TimeInterval, operation: @escaping @Sendable () -> Void)
        -> any IncidentCaptureScheduledTask
}

private final class DispatchIncidentCaptureTask: IncidentCaptureScheduledTask, @unchecked Sendable {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

final class DispatchIncidentCaptureScheduler: IncidentCaptureScheduler, @unchecked Sendable {
    func schedule(after interval: TimeInterval,
                  operation: @escaping @Sendable () -> Void) -> any IncidentCaptureScheduledTask {
        let item = DispatchWorkItem(block: operation)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, interval), execute: item)
        return DispatchIncidentCaptureTask(item: item)
    }
}

final class ManualIncidentCaptureScheduler: IncidentCaptureScheduler, @unchecked Sendable {
    private struct Entry {
        let deadline: TimeInterval
        let operation: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var entries: [UUID: Entry] = [:]

    @discardableResult
    func schedule(after interval: TimeInterval,
                  operation: @escaping @Sendable () -> Void) -> any IncidentCaptureScheduledTask {
        let id = UUID()
        lock.lock()
        entries[id] = Entry(deadline: now + max(0, interval), operation: operation)
        lock.unlock()
        return ManualIncidentCaptureTask { [weak self] in
            self?.lock.lock()
            self?.entries.removeValue(forKey: id)
            self?.lock.unlock()
        }
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        now += max(0, interval)
        let ready = entries.filter { $0.value.deadline <= now }
        ready.keys.forEach { entries.removeValue(forKey: $0) }
        lock.unlock()
        ready.values.forEach { $0.operation() }
    }
}

private final class ManualIncidentCaptureTask: IncidentCaptureScheduledTask, @unchecked Sendable {
    private let cancellation: () -> Void

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }
}

// Why: canonical contract owner.
// swiftlint:disable:next type_body_length
final class IncidentCaptureCoordinator: ObservableObject {
    static let maximumHistory = 50

    @Published private(set) var state: IncidentCaptureState = .idle
    @Published private(set) var activeSession: IncidentCaptureSession?
    @Published private(set) var incidents: [IncidentPackage] = []

    let journal: any EvidenceJournal
    let processRunID: UUID
    private let correlationService: IncidentCorrelationService?
    private let inferenceService: IncidentInferenceService?
    private let contextHistory: IncidentContextHistory?

    private let clock: any EvidenceClock
    private let scheduler: any IncidentCaptureScheduler
    private var scheduledTask: (any IncidentCaptureScheduledTask)?

    init(
        journal: any EvidenceJournal,
        clock: any EvidenceClock = SystemEvidenceClock(),
        scheduler: any IncidentCaptureScheduler = DispatchIncidentCaptureScheduler(),
        processRunID: UUID = UUID(),
        correlationService: IncidentCorrelationService? = nil,
        inferenceService: IncidentInferenceService? = nil,
        contextHistory: IncidentContextHistory? = nil
    ) {
        self.journal = journal
        self.clock = clock
        self.scheduler = scheduler
        self.processRunID = processRunID
        self.correlationService = correlationService
        self.inferenceService = inferenceService ?? IncidentInferenceService(journal: journal)
        self.contextHistory = contextHistory
        Task { [weak self] in
            await self?.recoverAndRefresh()
        }
    }

    @MainActor
    var isActive: Bool {
        switch state {
        case .starting, .capturing, .finalizing: return true
        default: return activeSession != nil
        }
    }

    @MainActor
    func start(context: IncidentContextSnapshot) {
        guard !isActive else { return }
        state = .starting
        Task { [weak self] in
            await self?.begin(context: context)
        }
    }

    @MainActor
    func refreshHistory() {
        Task { [weak self] in
            await self?.loadHistory()
        }
    }

    @MainActor
    func delete(_ incident: IncidentPackage) {
        Task { [weak self] in
            do {
                try await self?.journal.deleteIncident(id: incident.id)
                await self?.loadHistory()
            } catch {
                self?.state = .failure
            }
        }
    }

    @MainActor
    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    private func begin(context: IncidentContextSnapshot) async {
        let availability = await journal.retentionStatus().availability
        guard availability == .available else {
            state = availability == .capacityUnavailable ? .unavailable : .unavailable
            await loadHistory()
            return
        }

        let reading = clock.reading()
        let marker = IncidentMarker(
            markerID: UUID(),
            wallTime: reading.wallTime,
            continuousNanoseconds: reading.continuousNanoseconds,
            localSequence: nil,
            observationID: nil
        )
        let preStart = reading.wallTime
            .addingTimeInterval(-Double(Horizon2EvidenceConfiguration.incidentPreWindowSeconds))
        let preObservations = await journal.query(EvidenceJournalQuery(
            start: preStart,
            end: reading.wallTime,
            newestFirst: false
        ))
        let session = IncidentCaptureSession(
            id: UUID(),
            marker: marker,
            startedAt: reading.wallTime,
            processRunID: processRunID,
            materializedContext: context.values,
            observationIDs: preObservations.map(\.id),
            unknowns: context.unknowns
        )

        do {
            try await journal.beginIncidentCapture(session)
            activeSession = session
            state = .capturing
            scheduledTask?.cancel()
            scheduledTask = scheduler.schedule(
                after: TimeInterval(Horizon2EvidenceConfiguration.incidentPostWindowSeconds),
                operation: { [weak self] in
                    Task { @MainActor in
                        await self?.finalizeActiveCapture()
                    }
                }
            )
            await loadHistory()
        } catch let error as EvidenceJournalError {
            state = error == .capacityUnavailable || error == .unavailable ? .unavailable : .failure
            await loadHistory()
        } catch {
            state = .failure
            await loadHistory()
        }
    }

    @MainActor
    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    private func finalizeActiveCapture() async {
        guard let session = activeSession else { return }
        state = .finalizing
        let reading = clock.reading()
        let postEnd = session.marker.wallTime.addingTimeInterval(Double(session.postWindowSeconds))
        let interval = DateInterval(
            start: session.marker.wallTime.addingTimeInterval(-Double(session.preWindowSeconds)),
            end: postEnd
        )
        let observations = await journal.query(EvidenceJournalQuery(
            start: interval.start,
            end: interval.end,
            newestFirst: false
        ))
        var unknowns = session.unknowns
        let health = await journal.sourceHealth(in: interval)
        for record in health
            where record.event == .sourceUnavailable || record.event == .reconciliationFailure || record
            .reason == .incompleteCapture || record.reason == .journalCapacityUnavailable {
            unknowns.append(EvidenceMissing(
                sourceID: record.sourceID,
                reason: record.reason,
                explanation: "\(record.sourceID.rawValue) reported \(record.event.rawValue) during the capture window."
            ))
        }
        if reading.wallTime < session.marker.wallTime {
            unknowns.append(EvidenceMissing(
                sourceID: nil,
                reason: .wallClockDiscontinuity,
                explanation: "Wall time moved before the capture marker."
            ))
        }
        let availability = await journal.retentionStatus().availability
        if availability != .available {
            unknowns.append(EvidenceMissing(
                sourceID: nil,
                reason: .journalCapacityUnavailable,
                explanation: "Local evidence storage was unavailable while finalizing the capture."
            ))
        }
        var materializedContext = session.materializedContext
        if let contextHistory {
            let summary = contextHistory.summary(
                marker: session.marker.wallTime,
                preWindow: TimeInterval(session.preWindowSeconds),
                postWindow: TimeInterval(session.postWindowSeconds)
            )
            materializedContext = Self.contextWithWindowSummary(materializedContext, summary: summary)
            if summary.coverage != .complete {
                let sampleWord = summary.sampleCount == 1 ? "sample" : "samples"
                unknowns.append(EvidenceMissing(
                    sourceID: nil,
                    reason: .sourceCoverageGap,
                    explanation: "Telemetry context covered \(summary.sampleCount) \(sampleWord) from " +
                        "\(summary.coverage.rawValue.lowercased()) window coverage."
                ))
            }
        }
        let failureReason = unknowns.first?.reason
        let package = IncidentPackage(
            id: session.id,
            marker: session.marker,
            status: unknowns.isEmpty ? .complete : .incomplete,
            completedAt: reading.wallTime,
            materializedContext: materializedContext,
            observationIDs: observations.map(\.id),
            unknowns: unknowns,
            failureReason: failureReason
        )
        do {
            try await journal.finalizeIncidentCapture(package)
            if let correlationService {
                _ = try? await correlationService.process(incidentID: package.id)
                _ = try? await inferenceService?.process(incidentID: package.id)
            }
            scheduledTask = nil
            activeSession = nil
            state = package.status == .complete ? .complete : .incomplete
            await loadHistory()
        } catch {
            state = .failure
        }
    }

    @MainActor
    private func recoverAndRefresh() async {
        let sessions = await journal.activeIncidentCaptures()
        for session in sessions {
            if session.processRunID != processRunID {
                let reason = EvidenceMissing(
                    sourceID: nil,
                    reason: .processInterrupted,
                    explanation: "Small Matter was closed before the capture window finished."
                )
                let package = IncidentPackage(
                    id: session.id,
                    marker: session.marker,
                    status: .incomplete,
                    completedAt: nil,
                    materializedContext: session.materializedContext,
                    observationIDs: session.observationIDs,
                    unknowns: session.unknowns + [reason],
                    failureReason: .processInterrupted
                )
                try? await journal.finalizeIncidentCapture(package)
                if let correlationService {
                    _ = try? await correlationService.process(incidentID: package.id)
                    _ = try? await inferenceService?.process(incidentID: package.id)
                }
            } else if activeSession == nil {
                activeSession = session
                state = .capturing
                let elapsed = clock.reading().wallTime.timeIntervalSince(session.marker.wallTime)
                scheduledTask = scheduler.schedule(
                    after: max(0, TimeInterval(session.postWindowSeconds) - elapsed),
                    operation: { [weak self] in
                        Task { @MainActor in await self?.finalizeActiveCapture() }
                    }
                )
            }
        }
        await loadHistory()
    }

    @MainActor
    private func loadHistory() async {
        incidents = await journal.incidentSummaries(limit: Self.maximumHistory)
    }

    private static func contextWithWindowSummary(
        _ context: EvidenceValue,
        summary: IncidentWindowSummary
    ) -> EvidenceValue {
        guard case let .object(fields) = context else {
            return .object(["windowSummary": summary.evidenceValue])
        }
        var updated = fields
        updated["windowSummary"] = summary.evidenceValue
        return .object(updated)
    }
}

private extension ProcessInfo.ThermalState {
    var contextLabel: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
        // Why: cohesive reviewed boundary.
    }
} // swiftlint:disable:this file_length
