import SwiftUI

struct ThermalState {
    var cpuTemp: Double = 0
    var batteryTemp: Double = 0
    var cpuLoad: Double = 0
    var sustainedLoad = false
    var sustainedDuration: TimeInterval = 0

    var cpuTempDelta: Int {
        max(0, Int(cpuTemp - 55))
    }

    var batteryTempDelta: Int {
        max(0, Int(batteryTemp - 35))
    }

    var pressure: ThermalPressure {
        let totalDelta = cpuTempDelta + batteryTempDelta
        if totalDelta > 40 || cpuTemp > 95 {
            return .critical
        }
        if totalDelta > 25 || sustainedLoad {
            return .elevated
        }
        if totalDelta > 15 {
            return .moderate
        }
        return .nominal
    }

    var risk: RiskLevel {
        cpuTemp > 100 || batteryTemp > 50 ? .critical : .nominal
    }
}

enum ThermalPressure: String {
    case nominal = "Nominal"
    case moderate = "Moderate"
    case elevated = "Elevated"
    case critical = "Critical"

    var color: Color {
        switch self {
        case .nominal: .green
        case .moderate: .yellow
        case .elevated: .orange
        case .critical: .red
        }
    }
}

enum RiskLevel {
    case nominal
    case critical

    var shouldShowBanner: Bool {
        self == .critical
    }
}
