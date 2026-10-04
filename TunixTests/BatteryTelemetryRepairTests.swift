// swiftformat:disable trailingCommas
@testable import Tunix
import XCTest

@MainActor
final class BatteryTelemetryRepairTests: XCTestCase {
    func testCapacityModelPrefersTopLevelValues() {
        let registry: [String: Any] = [
            "AppleRawMaxCapacity": 7000,
            "NominalChargeCapacity": 7100,
            "DesignCapacity": 6800
        ]
        let batteryData: [String: Any] = [
            "FullChargeCapacity": 8000,
            "NominalChargeCapacity": 8100,
            "DesignCapacity": 8200
        ]

        XCTAssertEqual(
            BatteryCapacityModel.maximumCapacity(registry: registry, batteryData: batteryData),
            7000
        )
        XCTAssertEqual(
            BatteryCapacityModel.designCapacity(registry: registry, batteryData: batteryData),
            6800
        )
    }

    func testCapacityModelReadsNestedBatteryData() {
        let batteryData: [String: Any] = [
            "FullChargeCapacity": 8610,
            "DesignCapacity": 8579
        ]

        XCTAssertEqual(
            BatteryCapacityModel.maximumCapacity(registry: nil, batteryData: batteryData),
            8610
        )
        XCTAssertEqual(
            BatteryCapacityModel.designCapacity(registry: nil, batteryData: batteryData),
            8579
        )
    }

    func testCapacityModelFallsBackToNestedNominalCapacity() {
        let batteryData: [String: Any] = ["NominalChargeCapacity": 8854]

        XCTAssertEqual(
            BatteryCapacityModel.maximumCapacity(registry: nil, batteryData: batteryData),
            8854
        )
    }

    func testCapacityModelRejectsNonpositiveAndSentinelValues() {
        let registry: [String: Any] = [
            "AppleRawMaxCapacity": 0,
            "NominalChargeCapacity": 65535,
            "DesignCapacity": -1
        ]
        let batteryData: [String: Any] = [
            "FullChargeCapacity": 0,
            "NominalChargeCapacity": 65535,
            "DesignCapacity": 0
        ]

        XCTAssertNil(BatteryCapacityModel.maximumCapacity(registry: registry, batteryData: batteryData))
        XCTAssertNil(BatteryCapacityModel.designCapacity(registry: registry, batteryData: batteryData))
    }

    func testNativeReaderPopulatesAppleSMCBatteryTemperature() throws {
        let snapshot = try XCTUnwrap(
            NativeBatteryTelemetryReader.makeSnapshot(
                powerSource: nil,
                registry: [
                    "BatteryInstalled": true,
                    "BatteryData": [
                        "FullChargeCapacity": 8610,
                        "DesignCapacity": 8579
                    ]
                ],
                batteryTemperatureCelsius: 31.7
            )
        )

        guard let temperature = snapshot.temperatureCelsius else {
            XCTFail("Battery temperature was not populated")
            return
        }
        XCTAssertEqual(temperature, 31.7, accuracy: 0.01)
        XCTAssertEqual(snapshot.temperatureSource, .appleSMC)
        XCTAssertEqual(snapshot.maxCapacityMAh, 8610)
        XCTAssertEqual(snapshot.designCapacityMAh, 8579)
    }

    func testMissingAppleSMCBatteryTemperatureDoesNotPoisonOtherTelemetry() throws {
        let snapshot = try XCTUnwrap(
            NativeBatteryTelemetryReader.makeSnapshot(
                powerSource: nil,
                registry: [
                    "BatteryInstalled": true,
                    "BatteryData": [
                        "FullChargeCapacity": 8610,
                        "DesignCapacity": 8579
                    ]
                ],
                batteryTemperatureCelsius: nil
            )
        )

        XCTAssertNil(snapshot.temperatureCelsius)
        XCTAssertNil(snapshot.temperatureSource)
        XCTAssertEqual(snapshot.maxCapacityMAh, 8610)
        XCTAssertEqual(snapshot.designCapacityMAh, 8579)
        XCTAssertTrue(snapshot.present)
    }

    func testBatteryTemperatureGroupingIsDeterministicAndExcludesCPUAndGPU() {
        let groups = CoolingTemperaturePresentation.groups([
            CoolingTemperature(name: "Battery 0", valueCelsius: 30, sourceKey: "TB0T"),
            CoolingTemperature(name: "Battery 1", valueCelsius: 32, sourceKey: "TB1T"),
            CoolingTemperature(name: "CPU", valueCelsius: 87.8, sourceKey: "TC0P"),
            CoolingTemperature(name: "GPU", valueCelsius: 44, sourceKey: "TG0P")
        ])

        let battery = groups.first { $0.label == "Battery" }
        XCTAssertEqual(battery?.readingCount, 2)
        guard let batteryValue = battery?.valueCelsius else {
            XCTFail("Battery group was not produced")
            return
        }
        XCTAssertEqual(batteryValue, 31, accuracy: 0.01)
        XCTAssertEqual(groups.filter { $0.label == "CPU" }.count, 1)
        XCTAssertEqual(groups.filter { $0.label == "GPU" }.count, 1)
    }

    func testChargeDoesNotBecomeHealthAndHealthDisplayIsBounded() {
        let manager = BatteryManager(
            reader: RepairSequencedBatteryReader(
                results: [testSnapshot(stateOfChargePercent: 80, healthPercent: 100.36)]
            ),
            startTimer: false
        )

        XCTAssertEqual(manager.chargePercentString, "80%")
        XCTAssertEqual(manager.healthPercentString, "100%")
    }

    func testETAWordingReflectsPowerStateWhenETAIsUnavailable() {
        let connected = manager(
            isACConnected: true,
            isCharging: false,
            isFullyCharged: false
        )
        XCTAssertEqual(connected.timeToEmptyDisplay, "Connected to power")
        XCTAssertEqual(connected.timeToFullDisplay, "Not charging")

        let charging = manager(
            isACConnected: true,
            isCharging: true,
            isFullyCharged: false
        )
        XCTAssertEqual(charging.timeToEmptyDisplay, "Unavailable")
        XCTAssertEqual(charging.timeToFullDisplay, "Estimating…")

        let discharging = manager(
            isACConnected: false,
            isCharging: false,
            isFullyCharged: false
        )
        XCTAssertEqual(discharging.timeToEmptyDisplay, "Unavailable")
        XCTAssertEqual(discharging.timeToFullDisplay, "Unavailable")

        let full = manager(
            isACConnected: true,
            isCharging: false,
            isFullyCharged: true
        )
        XCTAssertEqual(full.timeToFullDisplay, "Fully charged")
    }

    private func manager(
        isACConnected: Bool,
        isCharging: Bool,
        isFullyCharged: Bool
    ) -> BatteryManager {
        BatteryManager(
            reader: RepairSequencedBatteryReader(
                results: [
                    testSnapshot(
                        isACConnected: isACConnected,
                        isCharging: isCharging,
                        isFullyCharged: isFullyCharged
                    )
                ]
            ),
            startTimer: false
        )
    }

    private func testSnapshot(
        isACConnected: Bool = true,
        isCharging: Bool = false,
        isFullyCharged: Bool = false,
        stateOfChargePercent: Double = 78,
        healthPercent: Double = 99.2
    ) -> BatterySnapshot {
        BatterySnapshot(
            timestamp: .now,
            availability: .valid,
            source: .ioRegistry,
            present: true,
            isACConnected: isACConnected,
            isCharging: isCharging,
            isFullyCharged: isFullyCharged,
            stateOfChargePercent: stateOfChargePercent,
            currentCapacityMAh: 6389,
            maxCapacityMAh: 8510,
            designCapacityMAh: 8579,
            healthPercent: healthPercent,
            cycleCount: 21,
            voltageMillivolts: 12234,
            currentMilliamps: 0,
            powerWatts: 0,
            temperatureCelsius: 27.25,
            timeToEmptyMinutes: nil,
            timeToFullMinutes: nil,
            temperatureSource: .appleSMC
        )
    }
}

private final class RepairSequencedBatteryReader: BatteryTelemetryReading {
    var results: [BatterySnapshot?]

    init(results: [BatterySnapshot?]) {
        self.results = results
    }

    func read() -> BatterySnapshot? {
        results.isEmpty ? nil : results.removeFirst()
    }
}

// swiftformat:enable trailingCommas
