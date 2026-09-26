@testable import Tunix
import XCTest

final class AdvancedMonitoringTests: XCTestCase {
    func testThermalTrendRecordingPreservesReadings() {
        let monitoring = AdvancedMonitoring()

        monitoring.recordThermalState(
            cpuTemp: 50,
            batteryTemp: 40,
            totalPower: 25,
            fanRPM: 2000,
            cpuUsage: 0.3
        )

        XCTAssertEqual(monitoring.thermalTrends.count, 1)
        XCTAssertEqual(monitoring.thermalTrends[0].cpuTemp, 50)
        XCTAssertEqual(monitoring.thermalTrends[0].batteryTemp, 40)
        XCTAssertEqual(monitoring.thermalTrends[0].fanRPM, 2000)
    }

    func testThermalHealthScoreForNormalReadingIsHealthy() {
        let monitoring = AdvancedMonitoring()

        monitoring.recordThermalState(
            cpuTemp: 50,
            batteryTemp: 35,
            totalPower: 20,
            fanRPM: 1500,
            cpuUsage: 0.2
        )

        XCTAssertGreaterThan(monitoring.getThermalHealthScore(), 70)
        XCTAssertLessThanOrEqual(monitoring.getThermalHealthScore(), 100)
    }

    func testSustainedLoadAnalysisUsesRecentPowerReadings() {
        let monitoring = AdvancedMonitoring()

        for _ in 0 ..< 25 {
            monitoring.recordPowerState(systemPower: 80, cpuPower: 40, gpuPower: 30, batteryPower: nil)
        }

        let result = monitoring.analyzeLoadPattern()

        XCTAssertTrue(result.sustained)
        XCTAssertEqual(result.averagePower, 80, accuracy: 0.001)
    }

    func testThermalHistoryRemainsBounded() {
        let monitoring = AdvancedMonitoring()

        for index in 0 ..< 1001 {
            monitoring.recordThermalState(
                cpuTemp: 50 + Double(index % 20),
                batteryTemp: 35,
                totalPower: 30,
                fanRPM: 2000,
                cpuUsage: 0.4
            )
        }

        XCTAssertEqual(monitoring.thermalTrends.count, 1000)
    }
}
