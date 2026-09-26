import Foundation
import SwiftUI

/// Observes thermal telemetry; macOS owns fan and charging policy.
@MainActor
final class ThermalManager: ObservableObject {
    @Published var thermalState = ThermalState()
    @Published private(set) var hasLiveThermalState = false

    private var loadHistory: [Double] = []
    private var sustainedLoadStart: Date?
    private let sustainedLoadThreshold: TimeInterval = 180

    func updateState(cpuTemp: Double, batteryTemp: Double, cpuLoad: Double) {
        thermalState.cpuTemp = cpuTemp
        thermalState.batteryTemp = batteryTemp
        thermalState.cpuLoad = cpuLoad
        hasLiveThermalState = true
        loadHistory.append(cpuLoad)
        if loadHistory.count > 36 {
            loadHistory.removeFirst()
        }

        let averageLoad = loadHistory.reduce(0, +) / Double(loadHistory.count)
        if averageLoad > 0.7 {
            sustainedLoadStart = sustainedLoadStart ?? Date()
            let duration = Date().timeIntervalSince(sustainedLoadStart ?? Date())
            thermalState.sustainedLoad = duration > sustainedLoadThreshold
            thermalState.sustainedDuration = duration
        } else {
            sustainedLoadStart = nil
            thermalState.sustainedLoad = false
            thermalState.sustainedDuration = 0
        }
    }

    var pressureDisplay: String {
        hasLiveThermalState ? thermalState.pressure.rawValue : "Unavailable"
    }

    var pressureColor: Color {
        hasLiveThermalState ? thermalState.pressure.color : .secondary
    }

    func clearState() {
        thermalState = ThermalState()
        hasLiveThermalState = false
        loadHistory.removeAll()
        sustainedLoadStart = nil
    }

    func reset() {
        clearState()
    }
}
