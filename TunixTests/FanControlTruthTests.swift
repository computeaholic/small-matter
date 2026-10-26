@testable import Tunix
import XCTest

final class FanControlTruthTests: XCTestCase {
    func testZeroRPMIsValidCoolingTelemetry() {
        let raw = CoolingRawObservation(
            fanCount: 1,
            fans: [CoolingFan(fanIndex: 0, currentRPM: 0, minimumRPM: 1350, maximumRPM: 5777)],
            temperatures: [CoolingTemperature(name: "Battery", valueCelsius: 31.1, sourceKey: "TB0T")],
            thermalState: .nominal
        )
        let snapshot = CoolingSnapshot(raw: raw, timestamp: .now, lastSuccessfulSampleAt: .now)

        XCTAssertEqual(snapshot.fans.first?.currentRPM, 0)
        XCTAssertEqual(snapshot.state, .available)
    }

    func testMissingFanKeysProducePartialCooling() {
        let raw = CoolingRawObservation(
            fanCount: nil,
            fans: [],
            temperatures: [CoolingTemperature(name: "Battery", valueCelsius: 31.1, sourceKey: "TB0T")],
            thermalState: .nominal
        )
        let snapshot = CoolingSnapshot(raw: raw, timestamp: .now, lastSuccessfulSampleAt: .now)

        XCTAssertEqual(snapshot.state, .partial)
        XCTAssertTrue(snapshot.fans.isEmpty)
    }

    func testCoolingFreshnessRetainsLastGoodSample() {
        let sampleDate = Date(timeIntervalSince1970: 100)
        let raw = CoolingRawObservation(
            fanCount: 1,
            fans: [CoolingFan(fanIndex: 0, currentRPM: 1362, minimumRPM: 1200, maximumRPM: 5000)],
            temperatures: [],
            thermalState: .nominal
        )
        let snapshot = CoolingSnapshot(raw: raw, timestamp: sampleDate, lastSuccessfulSampleAt: sampleDate)
        XCTAssertEqual(
            TelemetryHealth(
                lastAttemptAt: sampleDate.addingTimeInterval(8),
                lastSuccessfulSampleAt: sampleDate,
                consecutiveFailures: 1,
                staleAfter: 8,
                unavailableAfter: 30
            ).freshness(at: sampleDate.addingTimeInterval(8)),
            .stale
        )
        XCTAssertEqual(
            TelemetryHealth(
                lastAttemptAt: sampleDate.addingTimeInterval(30),
                lastSuccessfulSampleAt: sampleDate,
                consecutiveFailures: 2,
                staleAfter: 8,
                unavailableAfter: 30
            ).freshness(at: sampleDate.addingTimeInterval(30)),
            .unavailable
        )
        XCTAssertEqual(snapshot.fans.first?.currentRPM, 1362)
    }

    func testFanRangeIsLabeledAsReportedTelemetry() {
        let view = FanControlView()
        let fan = CoolingFan(fanIndex: 1, currentRPM: 5840, minimumRPM: 1350, maximumRPM: 5777)

        XCTAssertEqual(view.reportedRangeText(for: fan), "Reported range 1350–5777 RPM")
    }

    @MainActor
    func testCoolingServicePublishesAppProcessTelemetry() async {
        let source = StubCoolingSource(result: .success(
            CoolingRawObservation(
                fanCount: 1,
                fans: [CoolingFan(fanIndex: 0, currentRPM: 1400, minimumRPM: 1300, maximumRPM: 5700)],
                temperatures: [],
                thermalState: .nominal
            )
        ))
        let service = CoolingService(source: source, automaticallyStart: false)
        let expectation = expectation(description: "cooling sample")
        source.onCollect = { expectation.fulfill() }

        service.refresh()
        await fulfillment(of: [expectation], timeout: 1)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(service.snapshot.fans.first?.currentRPM, 1400)
        XCTAssertNotEqual(service.telemetryState, .unavailable)
    }

    @MainActor
    func testCoolingServiceRetainsThermalStateWhenSensorAccessIsDenied() async {
        let source = StubCoolingSource(result: .failure(.connectionUnavailable))
        let service = CoolingService(
            source: source,
            thermalStateReader: { .serious },
            automaticallyStart: false
        )
        let expectation = expectation(description: "cooling attempt")
        source.onCollect = { expectation.fulfill() }

        service.refresh()
        await fulfillment(of: [expectation], timeout: 1)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(service.snapshot.nativeThermalState, .serious)
        XCTAssertEqual(service.snapshot.thermalStateFreshness, .fresh)
        XCTAssertEqual(service.telemetryState, .partial)
        XCTAssertEqual(service.sensorStatus, .permissionDenied)
        XCTAssertTrue(service.sensorAvailabilityDescription.contains("permit"))
    }

    @MainActor
    func testCoolingServiceRecoversFromTemporarySensorFailure() async {
        let source = SequencedCoolingSource(results: [
            .failure(.keyUnreadable("F0Ac")),
            .success(
                CoolingRawObservation(
                    fanCount: 1,
                    fans: [CoolingFan(fanIndex: 0, currentRPM: 1400, minimumRPM: 1000, maximumRPM: 5000)],
                    temperatures: [CoolingTemperature(name: "CPU", valueCelsius: 44, sourceKey: "TC0P")],
                    thermalState: .fair
                )
            )
        ])
        let service = CoolingService(
            source: source,
            thermalStateReader: { .fair },
            automaticallyStart: false
        )

        let firstAttempt = expectation(description: "first cooling attempt")
        source.onCollect = { firstAttempt.fulfill() }
        service.refresh()
        await fulfillment(of: [firstAttempt], timeout: 1)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(service.sensorStatus, .temporarilyUnavailable)
        XCTAssertEqual(service.telemetryState, .partial)

        let secondAttempt = expectation(description: "second cooling attempt")
        source.onCollect = { secondAttempt.fulfill() }
        service.refresh()
        await fulfillment(of: [secondAttempt], timeout: 1)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(service.sensorStatus, .observed)
        XCTAssertEqual(service.telemetryState, .available)
        XCTAssertEqual(service.snapshot.fans.first?.currentRPM, 1400)
    }
}

private final class StubCoolingSource: CoolingTelemetrySource, @unchecked Sendable {
    let result: Result<CoolingRawObservation, CoolingCollectionError>
    var onCollect: (() -> Void)?

    init(result: Result<CoolingRawObservation, CoolingCollectionError>) {
        self.result = result
    }

    func collect() -> Result<CoolingRawObservation, CoolingCollectionError> {
        onCollect?()
        return result
    }
}

private final class SequencedCoolingSource: CoolingTelemetrySource, @unchecked Sendable {
    var results: [Result<CoolingRawObservation, CoolingCollectionError>]
    var onCollect: (() -> Void)?

    init(results: [Result<CoolingRawObservation, CoolingCollectionError>]) {
        self.results = results
    }

    func collect() -> Result<CoolingRawObservation, CoolingCollectionError> {
        onCollect?()
        return results.isEmpty ? .failure(.serviceUnavailable) : results.removeFirst()
    }
}
