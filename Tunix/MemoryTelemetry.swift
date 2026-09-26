import Foundation

/// The product-level memory vocabulary. Allocation answers "how much?";
/// pressure answers "is macOS under stress?" and neither substitutes for the
/// other.
enum MemoryPressureCondition: String, CaseIterable, Equatable {
    case normal
    case elevated
    case high
    case critical
    case unavailable

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .elevated: return "Elevated"
        case .high: return "High"
        case .critical: return "Critical"
        case .unavailable: return "Unavailable"
        }
    }

    /// Pressure events win over memory allocation.  In particular, a large
    /// machine may have high used memory and still be operating normally.
    static func classify(
        observed: MemoryPressureCondition,
        swapUsedBytes: UInt64?,
        physicalBytes: UInt64
    ) -> MemoryPressureCondition {
        guard observed == .unavailable else { return observed }
        guard let swapUsedBytes, physicalBytes > 0 else { return .unavailable }
        return Double(swapUsedBytes) / Double(physicalBytes) >= 0.25 ? .elevated : .normal
    }
}

struct MemoryTelemetry: Equatable {
    var pressure: MemoryPressureCondition = .normal
    var usedBytes: UInt64 = 0
    var physicalBytes: UInt64 = 0
    var appBytes: UInt64?
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var cachedBytes: UInt64?
    var swapUsedBytes: UInt64?

    static let unavailable = MemoryTelemetry(pressure: .unavailable)

    var usedPercent: Double? {
        guard physicalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(physicalBytes) * 100
    }
}

struct TelemetrySample: Identifiable, Equatable {
    let timestamp: Date
    let value: Double

    var id: Date {
        timestamp
    }
}

struct NetworkTelemetrySample: Identifiable, Equatable {
    let timestamp: Date
    let uploadBytesPerSecond: Double
    let downloadBytesPerSecond: Double

    var id: Date {
        timestamp
    }
}
