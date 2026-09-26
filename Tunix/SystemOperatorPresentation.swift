import Foundation
import SwiftUI

struct OperatorAction: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let cycleNumber: Int
}

extension SystemOperator {
    var pollingIntervalOptions: [TimeInterval] {
        [1.0, 2.0, 5.0, 10.0, 30.0, 60.0]
    }

    var pollingIntervalLabel: String {
        if pollingInterval < 60 {
            return "\(Int(pollingInterval))s"
        }
        return "\(Int(pollingInterval / 60))m"
    }

    var statusSummary: String {
        if !isEnabled {
            return "Disabled"
        }
        if !isRunning {
            return "Enabled (not running)"
        }
        return "Running (\(cycleCount) cycles)"
    }

    var healthStatus: OperatorHealth {
        if !isEnabled {
            return .disabled
        }
        if !isRunning {
            return .stopped
        }
        return .healthy
    }

    enum OperatorHealth {
        case healthy
        case stopped
        case disabled

        var label: String {
            switch self {
            case .healthy: return "Healthy"
            case .stopped: return "Stopped"
            case .disabled: return "Disabled"
            }
        }

        var color: Color {
            switch self {
            case .healthy: return .green
            case .stopped: return .yellow
            case .disabled: return .gray
            }
        }

        var icon: String {
            switch self {
            case .healthy: return "checkmark.circle.fill"
            case .stopped: return "pause.circle.fill"
            case .disabled: return "circle.slash"
            }
        }
    }
}
