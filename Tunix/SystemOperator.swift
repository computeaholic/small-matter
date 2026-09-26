import Foundation
import SwiftUI

/// Read-only system telemetry coordinator.
/// Small Matter observes system state; macOS owns thermal and charging policy.
@MainActor
final class SystemOperator: ObservableObject {
    @Published var isRunning = false
    @Published var lastAction: String = "Idle"
    @Published var actionHistory: [OperatorAction] = []
    @Published private(set) var cycleCount: Int = 0
    @Published var pollingInterval: TimeInterval = 5.0
    @Published var isEnabled = false
    init(thermalManager: ThermalManager, statsModel: SystemStatsModel, batteryManager: BatteryManager) {
        _ = thermalManager
        _ = statsModel
        _ = batteryManager
    }

    func start() {
        guard !isRunning, isEnabled else { return }
        isRunning = true
        lastAction = "Telemetry monitor started"
        logAction("Read-only telemetry monitor started")
        updateTelemetrySummary()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lastAction = "Telemetry monitor stopped"
        logAction("Read-only telemetry monitor stopped")
    }

    func restart() {
        stop()
        start()
    }

    private func updateTelemetrySummary() {
        // Domain collectors own their sampling loops.  This coordinator only
        // records the explicit lifecycle action and never starts a duplicate
        // CPU or battery polling timer.
        cycleCount += 1
        lastAction = "Observing hardware telemetry (cycle \(cycleCount))"
    }

    func logAction(_ message: String) {
        actionHistory.append(OperatorAction(timestamp: Date(), message: message, cycleNumber: cycleCount))
        if actionHistory.count > 100 {
            actionHistory.removeFirst()
        }
    }
}
