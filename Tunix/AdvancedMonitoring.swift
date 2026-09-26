import Foundation
import os.log

extension OSLog {
    static let monitoring = OSLog(subsystem: "com.tunix", category: "monitoring")
}

/// Advanced system monitoring with thermal trend analysis and power profiling
final class AdvancedMonitoring {
    struct ThermalPrediction {
        let predicted: Double
        let confidence: Double
        let mode: ThermalMode
    }

    /// FIX #8: THERMAL MODE AWARENESS (Fix #8)
    enum ThermalMode {
        case heating(rate: Double) // Heating up, approaching limit
        case throttling // At thermal limit, throttling occurring
        case cooling(rate: Double) // Cooling down after peak
        case stable // Temperature stable
    }

    struct ThermalTrend {
        let timestamp: Date
        let cpuTemp: Double
        let batteryTemp: Double
        let totalPower: Double? // watts, if available
        let fanRPM: Int?
        let cpuUsage: Double
        let predictedThermalIncrease: Double? // C/minute
    }

    struct PowerProfile {
        let timestamp: Date
        let systemPower: Double // Total system power (W)
        let cpuPower: Double? // CPU-specific power
        let gpuPower: Double? // GPU-specific power
        let batteryPower: Double? // Battery power draw
        let efficiency: Double? // Joules per unit work
    }

    private(set) var thermalTrends: [ThermalTrend] = []
    private(set) var powerProfiles: [PowerProfile] = []
    private(set) var thermalTrendSlope: Double = 0.0 // C/minute
    private(set) var estimatedThermalCapacity: Double = 100.0 // C above nominal

    private let maxHistorySize = 1000
    private let trendWindow: TimeInterval = 300 // 5-minute window for trend calc

    func recordThermalState(
        cpuTemp: Double,
        batteryTemp: Double,
        totalPower: Double?,
        fanRPM: Int?,
        cpuUsage: Double
    ) {
        let trend = ThermalTrend(
            timestamp: Date(),
            cpuTemp: cpuTemp,
            batteryTemp: batteryTemp,
            totalPower: totalPower,
            fanRPM: fanRPM,
            cpuUsage: cpuUsage,
            predictedThermalIncrease: calculateThermalDerivative(cpuTemp: cpuTemp)
        )

        thermalTrends.append(trend)

        // Keep history bounded
        if thermalTrends.count > maxHistorySize {
            thermalTrends.removeFirst(thermalTrends.count - maxHistorySize)
        }

        // Update trend analysis
        updateTrendAnalysis()
    }

    func recordPowerState(
        systemPower: Double,
        cpuPower: Double?,
        gpuPower: Double?,
        batteryPower: Double?
    ) {
        let profile = PowerProfile(
            timestamp: Date(),
            systemPower: systemPower,
            cpuPower: cpuPower,
            gpuPower: gpuPower,
            batteryPower: batteryPower,
            efficiency: calculateEfficiency(power: systemPower)
        )

        powerProfiles.append(profile)

        // Keep history bounded
        if powerProfiles.count > maxHistorySize {
            powerProfiles.removeFirst(powerProfiles.count - maxHistorySize)
        }
    }

    /// Calculate thermal slope (rate of temperature change in C/minute)
    private func calculateThermalDerivative(cpuTemp _: Double) -> Double? {
        guard thermalTrends.count >= 2 else { return nil }

        let now = Date()
        let recentTrends = thermalTrends.filter { now.timeIntervalSince($0.timestamp) < trendWindow }

        guard recentTrends.count >= 2 else { return nil }

        guard let first = recentTrends.first, let last = recentTrends.last else {
            return nil
        }

        let timeDelta = last.timestamp.timeIntervalSince(first.timestamp)
        let tempDelta = last.cpuTemp - first.cpuTemp

        guard timeDelta > 0 else { return nil }

        return (tempDelta / timeDelta) * 60.0 // Convert to C/minute
    }

    private func calculateEfficiency(power: Double) -> Double? {
        // Efficiency = inverse of power draw (lower power = higher efficiency)
        // Normalize to 0-1 scale where 1.0 = ideal efficiency
        return power > 0 ? 25.0 / power : nil // Assumes 25W is "reasonable" baseline
    }

    private func updateTrendAnalysis() {
        guard let latest = thermalTrends.last else { return }

        thermalTrendSlope = latest.predictedThermalIncrease ?? 0.0

        // Estimate thermal capacity by analyzing max reached temp vs power
        let maxTemp = thermalTrends.map { $0.cpuTemp }.max() ?? 0.0
        estimatedThermalCapacity = max(20.0, 120.0 - maxTemp)
    }

    /// Predict if thermal limit will be exceeded in next N seconds
    func predictThermalExceedance(
        currentTemp: Double,
        thermalLimit: Double,
        secondsAhead: Int
    ) -> (willExceed: Bool, estimatedTemp: Double) {
        let predictedDelta = thermalTrendSlope * Double(secondsAhead) / 60.0
        let estimatedTemp = currentTemp + predictedDelta

        return (estimatedTemp > thermalLimit, estimatedTemp)
    }

    /// FIX #8: Mode-aware thermal prediction with exponential decay and throttling detection
    func predictThermalWithMode(
        currentTemp: Double,
        thermalLimit: Double,
        secondsAhead: Int
    ) -> ThermalPrediction {
        let mode = detectThermalMode(currentTemp: currentTemp, thermalLimit: thermalLimit)

        let predicted: Double
        let confidence: Double

        switch mode {
        case .heating:
            // Exponential approach to limit with thermal time constant
            // tau = 300s (5 minutes) typical for CPU thermal response
            let tau = 300.0
            let headroom = thermalLimit - currentTemp
            let timeRatio = Double(secondsAhead) / tau

            // Exponential approach: temp = limit - headroom * exp(-t/tau)
            let predictedDelta = headroom * (1.0 - exp(-timeRatio))
            predicted = currentTemp + predictedDelta

            // Confidence is higher for shorter timeframes
            confidence = min(1.0, Double(secondsAhead) / 180.0) // Full confidence < 3 min

        case .throttling:
            // System is thermal throttling, temp stays near limit
            predicted = thermalLimit
            confidence = 1.0 // Very confident it stays near limit

        case let .cooling(rate):
            // Linear cooling with rate-based prediction
            // Cooling is typically slower than heating
            predicted = max(40.0, currentTemp - (rate * Double(secondsAhead) / 60.0))
            confidence = 0.7 // Less confident in cooling rates

        case .stable:
            // Temperature not changing
            predicted = currentTemp
            confidence = 0.95 // Very confident stable temp stays stable
        }

        return ThermalPrediction(predicted: predicted, confidence: confidence, mode: mode)
    }

    /// Detect thermal mode from current system state
    private func detectThermalMode(currentTemp: Double, thermalLimit: Double) -> ThermalMode {
        let tempMargin = thermalLimit - currentTemp
        let heatingRate = thermalTrendSlope

        // Check if actively throttling (temp very close to limit and high power draw)
        let isThrottlingCandidate = tempMargin < 5.0 // Within 5C of limit
        if isThrottlingCandidate, let latest = powerProfiles.last {
            if latest.systemPower > 30.0 { // High power draw
                return .throttling
            }
        }

        // Detect heating vs cooling
        if heatingRate > 1.0 { // Heating faster than 1C per minute
            return .heating(rate: heatingRate)
        } else if heatingRate < -0.5 { // Cooling at 0.5C+ per minute
            return .cooling(rate: abs(heatingRate))
        } else {
            return .stable // Rate within ±0.5C/min
        }
    }

    /// Suggest fan RPM based on thermal trend and system state
    func suggestFanRPM(
        currentTemp: Double,
        targetTemp: Double,
        thermalTrendSlope: Double,
        fanCount _: Int
    ) -> Int {
        // Base fan speed on current thermal pressure
        let tempPressure = max(0, currentTemp - targetTemp)

        // Consider trend - if heating up quickly, anticipate
        let trendFactor = max(0, thermalTrendSlope * 10) // Scale trend to fan RPM impact

        // Formula: 1200 base + (pressure × 50) + (trend × 100) + load factor
        let suggestedRPM = 1200 + Int(tempPressure * 50) + Int(trendFactor * 100)

        return min(6500, max(1200, suggestedRPM))
    }

    /// Analyze power pattern to detect sustained high power draw
    func analyzeLoadPattern() -> (sustained: Bool, averagePower: Double) {
        guard !powerProfiles.isEmpty else { return (false, 0) }

        let recentProfiles = powerProfiles.suffix(20) // Last 20 samples
        let avgPower = recentProfiles.map { $0.systemPower }.reduce(0, +) /
            Double(recentProfiles.count)

        // Sustained if average power > 75W and consistent
        let variance = recentProfiles.map { pow($0.systemPower - avgPower, 2) }.reduce(0, +) /
            Double(recentProfiles.count)
        let stdDev = sqrt(variance)

        let isSustained = avgPower > 75.0 && stdDev < 20.0 // High power with low variability

        return (isSustained, avgPower)
    }

    /// Get thermal health score (0-100)
    func getThermalHealthScore() -> Int {
        guard !thermalTrends.isEmpty else { return 100 }

        guard let latest = thermalTrends.last else { return 100 }

        // Deduct points for: high temp, rapid heating, low thermal capacity
        var score = 100

        // Temperature component (high temps reduce score)
        let tempPenalty = max(0, (latest.cpuTemp - 50.0) / 70.0 * 40.0) // 40 points for 50-120C
        score -= Int(tempPenalty)

        // Heating rate component (rapid heating reduces score)
        let trendPenalty = max(0, abs(thermalTrendSlope) * 10.0) // Up to 10 points
        score -= Int(trendPenalty)

        // Thermal capacity component
        let capacityPenalty = max(0, (20.0 - estimatedThermalCapacity) / 20.0 * 30.0) // 30 points
        score -= Int(capacityPenalty)

        return max(0, min(100, score))
    }

    /// Clear history (for testing or reset)
    func clearHistory() {
        thermalTrends.removeAll()
        powerProfiles.removeAll()
        thermalTrendSlope = 0
        estimatedThermalCapacity = 100
    }
}
