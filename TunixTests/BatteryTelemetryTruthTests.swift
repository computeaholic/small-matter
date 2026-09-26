@testable import Tunix
import XCTest

@MainActor
final class BatteryTelemetryTruthTests: XCTestCase {
    func testZeroChargeIsValidWhenBatteryCapacityIsKnown() {
        let status = BatteryStatus(isPresent: true, currentCapacity: 0, maxCapacity: 100)

        XCTAssertEqual(BatteryManager.chargePercent(from: status), 0)
    }

    func testMissingCapacityIsUnavailableRatherThanZero() {
        let status = BatteryStatus(isPresent: false, currentCapacity: 0, maxCapacity: 0)

        XCTAssertNil(BatteryManager.chargePercent(from: status))
    }

    func testMissingElectricalReadingsAreUnavailableRatherThanZero() {
        let missing = BatteryStatus(isPresent: true, currentCapacity: 50, maxCapacity: 100)
        let zero = BatteryStatus(
            isPresent: true,
            currentCapacity: 50,
            maxCapacity: 100,
            voltage: 0,
            amperage: 0,
            hasVoltageReading: true,
            hasAmperageReading: true
        )
        XCTAssertFalse(missing.hasVoltageReading)
        XCTAssertFalse(missing.hasAmperageReading)
        XCTAssertEqual(BatteryManager.chargePercent(from: missing), 50)
        XCTAssertTrue(zero.hasVoltageReading)
        XCTAssertTrue(zero.hasAmperageReading)
        XCTAssertEqual(zero.voltage, 0)
        XCTAssertEqual(zero.amperage, 0)
    }

    func testPowerUsesSignedMillivoltsTimesMilliamps() {
        XCTAssertEqual(
            BatteryPowerModel.watts(voltageMillivolts: 12000, currentMilliamps: 2500),
            30
        )
        XCTAssertEqual(
            BatteryPowerModel.watts(voltageMillivolts: 12000, currentMilliamps: -2500),
            -30
        )
        XCTAssertEqual(BatteryPowerModel.watts(voltageMillivolts: 12000, currentMilliamps: 0), 0)
        XCTAssertNil(BatteryPowerModel.watts(voltageMillivolts: nil, currentMilliamps: 0))
        XCTAssertNil(BatteryPowerModel.watts(voltageMillivolts: 0, currentMilliamps: 1))
    }

    func testTemperatureNormalizesTenthsKelvin() throws {
        XCTAssertEqual(
            try XCTUnwrap(BatteryPowerModel.temperatureCelsius(rawTenthsKelvin: 3004)),
            27.25,
            accuracy: 0.01
        )
        XCTAssertNil(BatteryPowerModel.temperatureCelsius(rawTenthsKelvin: nil))
        XCTAssertNil(BatteryPowerModel.temperatureCelsius(rawTenthsKelvin: 0))
    }

    func testHealthUsesMaximumAgainstDesignCapacity() throws {
        XCTAssertEqual(
            try XCTUnwrap(BatteryPowerModel.healthPercent(maxCapacityMAh: 8510, designCapacityMAh: 8579)),
            99.20,
            accuracy: 0.01
        )
        XCTAssertNil(BatteryPowerModel.healthPercent(maxCapacityMAh: 8510, designCapacityMAh: nil))
    }

    func testOperatingStateHasExplicitPowerSemantics() {
        XCTAssertEqual(
            BatteryStateResolver.resolve(present: true, isACConnected: true, isCharging: true, isFullyCharged: false),
            .charging
        )
        XCTAssertEqual(
            BatteryStateResolver.resolve(present: true, isACConnected: true, isCharging: false, isFullyCharged: true),
            .fullyCharged
        )
        XCTAssertEqual(
            BatteryStateResolver.resolve(present: true, isACConnected: true, isCharging: false, isFullyCharged: false),
            .connectedNotCharging
        )
        XCTAssertEqual(
            BatteryStateResolver.resolve(present: true, isACConnected: false, isCharging: false, isFullyCharged: false),
            .discharging
        )
        XCTAssertEqual(
            BatteryStateResolver.resolve(
                present: false,
                isACConnected: false,
                isCharging: false,
                isFullyCharged: false
            ),
            .unavailable
        )
    }

    func testTelemetryHealthDistinguishesValidStaleAndUnavailable() {
        let sample = Date(timeIntervalSince1970: 1000)
        let health = BatteryTelemetryHealth(
            lastSuccessfulSampleAt: sample,
            staleAfter: 15,
            unavailableAfter: 60
        )

        XCTAssertEqual(health.state(at: sample.addingTimeInterval(14)), .valid)
        XCTAssertEqual(health.state(at: sample.addingTimeInterval(15)), .stale)
        XCTAssertEqual(health.state(at: sample.addingTimeInterval(60)), .unavailable)
    }

    func testSnapshotAvailabilityChangePreservesOneCoherentSample() {
        let timestamp = Date(timeIntervalSince1970: 2000)
        let snapshot = BatterySnapshot(
            timestamp: timestamp,
            availability: .valid,
            source: .ioRegistry,
            present: true,
            isACConnected: true,
            isCharging: false,
            isFullyCharged: false,
            stateOfChargePercent: 78,
            currentCapacityMAh: 6389,
            maxCapacityMAh: 8510,
            designCapacityMAh: 8579,
            healthPercent: 99.2,
            cycleCount: 21,
            voltageMillivolts: 12234,
            currentMilliamps: 0,
            powerWatts: 0,
            temperatureCelsius: 27.25,
            timeToEmptyMinutes: nil,
            timeToFullMinutes: nil
        )

        let stale = snapshot.withAvailability(.stale)
        XCTAssertEqual(stale.timestamp, timestamp)
        XCTAssertEqual(stale.stateOfChargePercent, 78)
        XCTAssertEqual(stale.voltageMillivolts, 12234)
        XCTAssertEqual(stale.currentMilliamps, 0)
        XCTAssertEqual(stale.powerWatts, 0)
        XCTAssertEqual(stale.cycleCount, 21)
    }

    func testManagerRetainsLastGoodSnapshotAfterTransientFailure() {
        let timestamp = Date()
        let reader = SequencedBatteryReader(results: [testSnapshot(timestamp: timestamp), nil])
        let manager = BatteryManager(reader: reader, startTimer: false)

        XCTAssertEqual(manager.snapshot.availability, .valid)
        XCTAssertEqual(manager.snapshot.currentMilliamps, 0)

        manager.refresh()
        XCTAssertEqual(manager.snapshot.currentCapacityMAh, 6389)
        XCTAssertEqual(manager.snapshot.availability, .valid)
        manager.updateTelemetryState(now: timestamp.addingTimeInterval(15))
        XCTAssertEqual(manager.snapshot.availability, .stale)
        manager.updateTelemetryState(now: timestamp.addingTimeInterval(60))
        XCTAssertEqual(manager.snapshot.availability, .unavailable)
    }

    private func testSnapshot(timestamp: Date) -> BatterySnapshot {
        BatterySnapshot(
            timestamp: timestamp,
            availability: .valid,
            source: .ioRegistry,
            present: true,
            isACConnected: true,
            isCharging: false,
            isFullyCharged: false,
            stateOfChargePercent: 78,
            currentCapacityMAh: 6389,
            maxCapacityMAh: 8510,
            designCapacityMAh: 8579,
            healthPercent: 99.2,
            cycleCount: 21,
            voltageMillivolts: 12234,
            currentMilliamps: 0,
            powerWatts: 0,
            temperatureCelsius: 27.25,
            timeToEmptyMinutes: nil,
            timeToFullMinutes: nil
        )
    }
}

private final class SequencedBatteryReader: BatteryTelemetryReading {
    var results: [BatterySnapshot?]

    init(results: [BatterySnapshot?]) {
        self.results = results
    }

    func read() -> BatterySnapshot? {
        results.isEmpty ? nil : results.removeFirst()
    }
}
