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
