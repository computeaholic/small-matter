import Darwin
import Foundation
import IOKit
import SwiftUI

@MainActor
// swiftlint:disable:next type_body_length
final class SystemStatsModel: ObservableObject {
    @Published private(set) var telemetrySnapshot = SystemTelemetrySnapshot.unavailable
    @Published private(set) var lastSuccessfulTelemetryAt: Date?

    private var timer: Timer?
    private var previousProcessorTicks: [ProcessorCPUTicks] = []
    private var previousNetworkSample: NetworkSample?
    private var cpuHistoryBuffer = BoundedHistory<TelemetrySample>(limit: 60)
    private var memoryHistoryBuffer = BoundedHistory<TelemetrySample>(limit: 60)
    private var networkHistoryBuffer = BoundedHistory<NetworkTelemetrySample>(limit: 60)
    private var refreshInterval: TimeInterval
    private var isBackgrounded = false
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Thermal manager for profile-based thermal response
    var thermalManager: ThermalManager?

    init(
        refreshInterval: TimeInterval = 1,
        thermalManager: ThermalManager? = nil
    ) {
        self.refreshInterval = refreshInterval
        self.thermalManager = thermalManager
        setupMemoryPressureSource()
        setupBackgroundNotifications()
        start()
    }

    private func setupBackgroundNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isBackgrounded = true
                self?.restartTimer()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isBackgrounded = false
                self?.restartTimer()
            }
        }
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = max(1, interval)
        restartTimer()
    }

    func update() {
        let timestamp = Date()
        let cpu = updateCPU(timestamp: timestamp)
        let memory = updateMemory(timestamp: timestamp)
        let storage = updateDisk(timestamp: timestamp)
        let network = updateNetwork(timestamp: timestamp)
        let thermal = updateThermals(timestamp: timestamp)
        telemetrySnapshot = SystemTelemetrySnapshot(
            timestamp: timestamp,
            cpu: cpu,
            memory: memory,
            network: network,
            storage: storage,
            thermal: thermal
        )
        lastSuccessfulTelemetryAt = timestamp
    }

    private func start() {
        update()
        let interval = isBackgrounded ? refreshInterval * 4 : refreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        start()
    }

    deinit {
        timer?.invalidate()
        memoryPressureSource?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func updateCPU(timestamp: Date) -> CPUSnapshot {
        let current = Self.readProcessorCPUTicks()
        guard !current.isEmpty else { return telemetrySnapshot.cpu }

        if let result = CPUUsageCalculator.calculate(previous: previousProcessorTicks, current: current) {
            let snapshot = CPUSnapshot(timestamp: timestamp, result: result)
            cpuHistoryBuffer.append(TelemetrySample(timestamp: timestamp, value: snapshot.totalUtilization))
            previousProcessorTicks = current
            return snapshot
        }

        previousProcessorTicks = current
        return telemetrySnapshot.cpu
    }

    private func updateMemory(timestamp: Date) -> MemorySnapshot {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return telemetrySnapshot.memory }

        let physical = ProcessInfo.processInfo.physicalMemory
        let used = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * UInt64(pageSize)
        let wired = UInt64(stats.wire_count) * UInt64(pageSize)
        let compressed = UInt64(stats.compressor_page_count) * UInt64(pageSize)
        let cached = UInt64(stats.purgeable_count + stats.external_page_count) * UInt64(pageSize)
        let app = Self.fetchApplicationMemoryBytes()
        let swap = Self.fetchSwapUsedBytes()
        let telemetry = MemoryTelemetry(
            pressure: MemoryPressureCondition.classify(
                observed: memoryPressureCondition,
                swapUsedBytes: swap,
                physicalBytes: physical
            ),
            usedBytes: used,
            physicalBytes: physical,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: cached,
            swapUsedBytes: swap
        )
        memoryHistoryBuffer.append(TelemetrySample(timestamp: timestamp, value: Double(used)))
        return MemorySnapshot(
            timestamp: timestamp,
            freshness: .fresh,
            source: .machVM,
            telemetry: telemetry
        )
    }

    private func updateDisk(timestamp: Date) -> StorageSnapshot {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/")
        let free = attributes?[.systemFreeSize] as? NSNumber
        let total = attributes?[.systemSize] as? NSNumber
        guard let free, let total else { return telemetrySnapshot.storage }
        return StorageSnapshot(
            timestamp: timestamp,
            freshness: .fresh,
            source: .fileSystem,
            freeBytes: free.uint64Value,
            totalBytes: total.uint64Value
        )
    }

    private func updateNetwork(timestamp: Date) -> NetworkSnapshot {
        let sample = Self.fetchNetworkSample(timestamp: timestamp)
        guard sample.isValid else { return telemetrySnapshot.network }

        var uploadRate: Double?
        var downloadRate: Double?
        if let previous = previousNetworkSample {
            let deltaTime = timestamp.timeIntervalSince(previous.timestamp)
            if deltaTime > 0, sample.sent >= previous.sent, sample.received >= previous.received {
                let sentDelta = Double(sample.sent - previous.sent)
                let receivedDelta = Double(sample.received - previous.received)
                uploadRate = sentDelta / deltaTime
                downloadRate = receivedDelta / deltaTime
                networkHistoryBuffer.append(
                    NetworkTelemetrySample(
                        timestamp: timestamp,
                        uploadBytesPerSecond: uploadRate ?? 0,
                        downloadBytesPerSecond: downloadRate ?? 0
                    )
                )
            }
        }

        previousNetworkSample = sample
        return NetworkSnapshot(
            timestamp: timestamp,
            freshness: .fresh,
            source: .networkInterfaces,
            sentBytes: sample.sent,
            receivedBytes: sample.received,
            uploadBytesPerSecond: uploadRate,
            downloadBytesPerSecond: downloadRate
        )
    }

    private func updateThermals(timestamp: Date) -> SystemThermalSnapshot {
        SystemThermalSnapshot(
            timestamp: timestamp,
            freshness: .fresh,
            source: .processInfo,
            thermalState: ProcessInfo.processInfo.thermalState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            cpuTemperatureCelsius: nil,
            batteryTemperatureCelsius: nil
        )
    }

    private var memoryPressureCondition: MemoryPressureCondition = .normal

    private func setupMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.critical) {
                self.memoryPressureCondition = .critical
            } else if event.contains(.warning) {
                self.memoryPressureCondition = .elevated
            } else if event.contains(.normal) {
                self.memoryPressureCondition = .normal
            }
            let current = self.telemetrySnapshot.memory
            var telemetry = current.telemetry
            telemetry.pressure = self.memoryPressureCondition
            self.telemetrySnapshot = SystemTelemetrySnapshot(
                timestamp: self.telemetrySnapshot.timestamp,
                cpu: self.telemetrySnapshot.cpu,
                memory: MemorySnapshot(
                    timestamp: current.timestamp,
                    freshness: current.freshness,
                    source: current.source,
                    telemetry: telemetry
                ),
                network: self.telemetrySnapshot.network,
                storage: self.telemetrySnapshot.storage,
                thermal: self.telemetrySnapshot.thermal
            )
        }
        memoryPressureSource = source
        source.resume()
    }

    private static func fetchApplicationMemoryBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    private static func readProcessorCPUTicks() -> [ProcessorCPUTicks] {
        var processorInfo: processor_info_array_t?
        var processorCount: natural_t = 0
        var processorInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )
        guard result == KERN_SUCCESS, let processorInfo else { return [] }

        defer {
            let address = vm_address_t(bitPattern: processorInfo)
            let size = vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, address, size)
        }

        return processorInfo.withMemoryRebound(
            to: processor_cpu_load_info.self,
            capacity: Int(processorCount)
        ) { loadInfo in
            (0 ..< Int(processorCount)).map { index in
                let ticks = loadInfo[index].cpu_ticks
                return ProcessorCPUTicks(
                    identifier: index,
                    user: UInt64(ticks.0),
                    system: UInt64(ticks.1),
                    idle: UInt64(ticks.2),
                    nice: UInt64(ticks.3)
                )
            }
        }
    }

    private static func fetchSwapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            sysctlbyname("vm.swapusage", pointer, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return usage.xsu_used
    }
}

extension SystemStatsModel {
    var cpuUsage: Double {
        cpuSnapshot.totalUtilization
    }

    var cpuSnapshot: CPUSnapshot {
        telemetrySnapshot.cpu
    }

    var memoryUsedBytes: UInt64 {
        memoryTelemetry.usedBytes
    }

    var memoryTotalBytes: UInt64 {
        memoryTelemetry.physicalBytes
    }

    var memoryFreeBytes: UInt64 {
        memoryTelemetry.physicalBytes - min(memoryTelemetry.usedBytes, memoryTelemetry.physicalBytes)
    }

    var memoryTelemetry: MemoryTelemetry {
        telemetrySnapshot.memory.telemetry
    }

    var memoryHasSample: Bool {
        telemetrySnapshot.memory.freshness != .unavailable
    }

    var cpuHistory: [TelemetrySample] {
        cpuHistoryBuffer.values
    }

    var memoryHistory: [TelemetrySample] {
        memoryHistoryBuffer.values
    }

    var networkHistory: [NetworkTelemetrySample] {
        networkHistoryBuffer.values
    }

    var diskFreeBytes: UInt64 {
        storageSnapshot.freeBytes ?? 0
    }

    var diskTotalBytes: UInt64 {
        storageSnapshot.totalBytes ?? 0
    }

    var storageHasSample: Bool {
        storageSnapshot.freeBytes != nil && storageSnapshot.totalBytes != nil
    }

    var networkSentBytes: UInt64 {
        networkSnapshot.sentBytes ?? 0
    }

    var networkReceivedBytes: UInt64 {
        networkSnapshot.receivedBytes ?? 0
    }

    var networkUploadRate: Double {
        networkSnapshot.uploadBytesPerSecond ?? 0
    }

    var networkDownloadRate: Double {
        networkSnapshot.downloadBytesPerSecond ?? 0
    }

    var thermalState: ProcessInfo.ThermalState {
        telemetrySnapshot.thermal.thermalState
    }

    var lowPowerMode: Bool {
        telemetrySnapshot.thermal.lowPowerMode
    }

    var lastUpdated: Date {
        telemetrySnapshot.timestamp
    }

    var storageSnapshot: StorageSnapshot {
        telemetrySnapshot.storage
    }

    var networkSnapshot: NetworkSnapshot {
        telemetrySnapshot.network
    }

    var diskFreeText: String {
        storageSnapshot.freeBytes.map { Self.byteFormatter.string(fromByteCount: Int64($0)) } ?? "Unavailable"
    }

    var diskTotalText: String {
        storageSnapshot.totalBytes.map { Self.byteFormatter.string(fromByteCount: Int64($0)) } ?? "Unavailable"
    }

    var memoryFreeText: String {
        memoryHeadline
    }

    var memoryHeadline: String {
        "\(memoryUsedText) / \(memoryPhysicalText)"
    }

    var memoryUsedText: String {
        memoryHasSample
            ? Self.memoryByteFormatter.string(fromByteCount: Int64(memoryTelemetry.usedBytes))
            : "Unavailable"
    }

    var memoryUsagePercent: Double? {
        guard memoryTelemetry.physicalBytes > 0 else { return nil }
        return Double(memoryTelemetry.usedBytes) / Double(memoryTelemetry.physicalBytes) * 100
    }

    var memoryUsagePercentText: String {
        memoryUsagePercent.map { String(format: "%.0f%%", $0) } ?? "Unavailable"
    }

    var memoryPressureDetail: String {
        "Used \(Self.memoryByteFormatter.string(fromByteCount: Int64(memoryTelemetry.usedBytes))) • " +
            "Swap \(memorySwapText)"
    }

    var memoryPhysicalText: String {
        memoryTelemetry.physicalBytes > 0
            ? Self.memoryByteFormatter.string(fromByteCount: Int64(memoryTelemetry.physicalBytes))
            : "Unavailable"
    }

    var memoryAppText: String {
        memoryTelemetry.appBytes.map { Self.memoryByteFormatter.string(fromByteCount: Int64($0)) } ?? "Unavailable"
    }

    var memoryWiredText: String {
        memoryHasSample
            ? Self.memoryByteFormatter.string(fromByteCount: Int64(memoryTelemetry.wiredBytes))
            : "Unavailable"
    }

    var memoryCompressedText: String {
        memoryHasSample
            ? Self.memoryByteFormatter.string(fromByteCount: Int64(memoryTelemetry.compressedBytes))
            : "Unavailable"
    }

    var memoryCachedText: String {
        memoryTelemetry.cachedBytes.map { Self.memoryByteFormatter.string(fromByteCount: Int64($0)) } ?? "Unavailable"
    }

    var memorySwapText: String {
        memoryTelemetry.swapUsedBytes.map { Self.memoryByteFormatter.string(fromByteCount: Int64($0)) } ?? "Unavailable"
    }

    var networkUploadRateText: String {
        networkSnapshot.uploadBytesPerSecond.map {
            Self.rateFormatter.string(fromByteCount: Int64($0)) + "/s"
        } ?? "Unavailable"
    }

    var networkDownloadRateText: String {
        networkSnapshot.downloadBytesPerSecond.map {
            Self.rateFormatter.string(fromByteCount: Int64($0)) + "/s"
        } ?? "Unavailable"
    }

    var memoryPressureLabel: String {
        memoryTelemetry.pressure.label
    }

    var thermalStateLabel: String {
        guard telemetrySnapshot.thermal.freshness != .unavailable else { return "Unavailable" }
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var thermalConditionLabel: String {
        guard telemetrySnapshot.thermal.freshness != .unavailable else { return "Unavailable" }
        switch thermalState {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Elevated"
        case .critical: return "Critical"
        @unknown default: return "Unavailable"
        }
    }

    var thermalStateDetail: String {
        "Apple thermal state: \(thermalStateLabel) • " +
            (lowPowerMode ? "Low Power Mode" : "Standard Power")
    }

    var thermalStateColor: Color {
        guard telemetrySnapshot.thermal.freshness != .unavailable else { return .secondary }
        switch thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    var cpuUsageText: String {
        cpuSnapshot.freshness == .unavailable ? "Unavailable" : String(format: "%.0f%%", cpuSnapshot.totalUtilization)
    }

    var cpuUserText: String {
        cpuSnapshot.freshness == .unavailable ? "Unavailable" : String(format: "%.0f%%", cpuSnapshot.userUtilization)
    }

    var cpuSystemText: String {
        cpuSnapshot.freshness == .unavailable ? "Unavailable" : String(format: "%.0f%%", cpuSnapshot.systemUtilization)
    }

    var cpuIdleText: String {
        cpuSnapshot.freshness == .unavailable ? "Unavailable" : String(format: "%.0f%%", cpuSnapshot.idleUtilization)
    }

    var logicalCPUText: String {
        cpuSnapshot.logicalCPUCount > 0 ? "\(cpuSnapshot.logicalCPUCount)" : "Unavailable"
    }

    var systemTelemetryStatusLabel: String {
        telemetrySnapshot.cpu.freshness.label
    }

    var systemTelemetryIsAvailable: Bool {
        telemetrySnapshot.cpu.freshness == .fresh
    }

    var lastTelemetryUpdatedText: String {
        guard let lastSuccessfulTelemetryAt else { return "Unavailable" }
        return lastSuccessfulTelemetryAt.formatted(date: .omitted, time: .shortened)
    }

    var networkInterfaceLabel: String {
        "All active interfaces"
    }

    private struct NetworkSample {
        let sent: UInt64
        let received: UInt64
        let timestamp: Date
        let isValid: Bool
    }

    private static func fetchNetworkSample(timestamp: Date) -> NetworkSample {
        var sent: UInt64 = 0
        var received: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return NetworkSample(sent: 0, received: 0, timestamp: timestamp, isValid: false)
        }

        var current = first
        while true {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            if isUp, let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let name = String(cString: interface.ifa_name)
                if name != "lo0" {
                    sent += UInt64(data.pointee.ifi_obytes)
                    received += UInt64(data.pointee.ifi_ibytes)
                }
            }

            if let next = interface.ifa_next {
                current = next
            } else {
                break
            }
        }

        freeifaddrs(first)
        return NetworkSample(sent: sent, received: received, timestamp: timestamp, isValid: true)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let memoryByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }()

    private static let rateFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    // swiftlint:disable:next file_length
}
