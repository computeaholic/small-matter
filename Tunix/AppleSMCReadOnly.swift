// swiftformat:disable trailingCommas
import Foundation
import IOKit
import os.log

protocol CoolingTelemetrySource: AnyObject, Sendable {
    func collect() -> Result<CoolingRawObservation, CoolingCollectionError>
}

struct CoolingRawObservation: Equatable, Sendable {
    let fanCount: Int?
    let fans: [CoolingFan]
    let temperatures: [CoolingTemperature]
    let thermalState: ProcessInfo.ThermalState
}

enum CoolingCollectionError: Error, Sendable {
    case serviceUnavailable
    case connectionUnavailable
    case keyUnreadable(String)
    case noSupportedKeys
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // swiftlint:disable:next large_tuple
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private struct SMCKeyData {
    var key: UInt32 = 0
    // swiftlint:disable:next large_tuple
    var vers: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    // swiftlint:disable:next large_tuple
    var pLimitData: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    // swiftlint:disable:next large_tuple
    var padding0: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var padding1: UInt8 = 0
    var data32: UInt32 = 0
    // swiftlint:disable:next large_tuple
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private struct SMCReadResult {
    let dataType: UInt32
    let bytes: [UInt8]
}

private enum SMCReadCommand: UInt8 {
    case readBytes = 5
    case readKeyInfo = 9
}

/// The app-process AppleSMC boundary intentionally exposes collection only.
/// It has no write command, write method, target setter, or arbitrary command
/// parameter. All IOKit calls below are limited to key-info and key-byte reads.
final class AppleSMCReadOnlyReader: CoolingTelemetrySource, @unchecked Sendable {
    private static let serviceName = "AppleSMC"
    private static let fanTemperatureKeys = [
        "TC0P", "TC0E", "TC0D", "TC0F", "Tp0P", "Tp0p",
        "TB0T", "TB1T", "TB2T", "TBAT", "TG0P", "TG0D"
    ]

    private let service: io_service_t

    init() {
        service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(Self.serviceName)
        )
    }

    deinit {
        if service != IO_OBJECT_NULL {
            IOObjectRelease(service)
        }
    }

    func collect() -> Result<CoolingRawObservation, CoolingCollectionError> {
        do {
            let connection = try openConnection()
            defer { IOServiceClose(connection) }

            let fanCount = readNumeric("FNum", connection: connection).flatMap(Self.safeInteger).map { max(0, $0) }
            let fans = readFans(fanCount: fanCount, connection: connection)
            let temperatures = readTemperatures(connection: connection)

            guard fanCount != nil || !fans.isEmpty || !temperatures.isEmpty else {
                throw CoolingCollectionError.noSupportedKeys
            }

            return .success(
                CoolingRawObservation(
                    fanCount: fanCount ?? (fans.isEmpty ? nil : fans.count),
                    fans: fans,
                    temperatures: temperatures,
                    thermalState: ProcessInfo.processInfo.thermalState
                )
            )
        } catch let error as CoolingCollectionError {
            os_log(
                "AppleSMC read-only cooling collection failed: %{public}@",
                log: TunixLogging.thermal,
                type: .error,
                String(describing: error)
            )
            return .failure(error)
        } catch {
            return .failure(.keyUnreadable("Unexpected read failure"))
        }
    }

    private func readFans(fanCount: Int?, connection: io_connect_t) -> [CoolingFan] {
        let discoveredFanCount = fanCount ?? Self.discoverFanCount { key in
            readNumeric(key, connection: connection)
        }
        return (0 ..< min(discoveredFanCount ?? 0, 8)).compactMap { index -> CoolingFan? in
            guard let current = readNumeric("F\(index)Ac", connection: connection).flatMap(Self.safeInteger) else {
                return nil
            }
            return CoolingFan(
                fanIndex: index,
                currentRPM: max(0, current),
                minimumRPM: readNumeric("F\(index)Mn", connection: connection)
                    .flatMap(Self.safeInteger)
                    .map { max(0, $0) },
                maximumRPM: readNumeric("F\(index)Mx", connection: connection)
                    .flatMap(Self.safeInteger)
                    .map { max(0, $0) }
            )
        }
    }

    private func readTemperatures(connection: io_connect_t) -> [CoolingTemperature] {
        Self.fanTemperatureKeys.compactMap { key -> CoolingTemperature? in
            guard let value = readNumeric(key, connection: connection),
                  value.isFinite,
                  value > 0,
                  value < 120
            else { return nil }
            return CoolingTemperature(
                name: Self.temperatureName(for: key),
                valueCelsius: value,
                sourceKey: key
            )
        }
    }

    private func openConnection() throws -> io_connect_t {
        guard service != IO_OBJECT_NULL else {
            throw CoolingCollectionError.serviceUnavailable
        }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            throw CoolingCollectionError.connectionUnavailable
        }
        return connection
    }

    private func readNumeric(_ key: String, connection: io_connect_t) -> Double? {
        guard let result = try? readKey(key, connection: connection) else { return nil }
        return Self.decodeNumeric(result)
    }

    private func readKey(_ key: String, connection: io_connect_t) throws -> SMCReadResult {
        var infoInput = SMCKeyData()
        infoInput.key = Self.encodeKey(key)
        infoInput.data8 = SMCReadCommand.readKeyInfo.rawValue
        var infoOutput = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride

        guard IOConnectCallStructMethod(
            connection,
            2,
            &infoInput,
            size,
            &infoOutput,
            &size
        ) == kIOReturnSuccess,
            infoOutput.result == 0,
            infoOutput.keyInfo.dataSize > 0,
            infoOutput.keyInfo.dataSize <= 32
        else {
            throw CoolingCollectionError.keyUnreadable(key)
        }

        var readInput = SMCKeyData()
        readInput.key = Self.encodeKey(key)
        readInput.keyInfo = infoOutput.keyInfo
        readInput.data8 = SMCReadCommand.readBytes.rawValue
        var readOutput = SMCKeyData()
        size = MemoryLayout<SMCKeyData>.stride

        guard IOConnectCallStructMethod(
            connection,
            2,
            &readInput,
            size,
            &readOutput,
            &size
        ) == kIOReturnSuccess,
            readOutput.result == 0
        else {
            throw CoolingCollectionError.keyUnreadable(key)
        }

        let bytes = withUnsafeBytes(of: readOutput.bytes) {
            Array($0.prefix(Int(infoOutput.keyInfo.dataSize)))
        }
        return SMCReadResult(dataType: infoOutput.keyInfo.dataType, bytes: bytes)
    }

    private static func discoverFanCount(readableWith read: (String) -> Double?) -> Int? {
        let indexes = (0 ..< 8).filter { read("F\($0)Ac") != nil }
        return indexes.max().map { $0 + 1 }
    }

    private static func safeInteger(_ value: Double) -> Int? {
        guard value.isFinite,
              value >= Double(Int.min),
              value <= Double(Int.max)
        else { return nil }
        return Int(value.rounded())
    }

    private static func encodeKey(_ key: String) -> UInt32 {
        key.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func typeString(_ type: UInt32) -> String {
        String(
            bytes: [
                UInt8((type >> 24) & 0xFF),
                UInt8((type >> 16) & 0xFF),
                UInt8((type >> 8) & 0xFF),
                UInt8(type & 0xFF)
            ],
            encoding: .ascii
        ) ?? ""
    }

    private static func decodeNumeric(_ result: SMCReadResult) -> Double? {
        switch typeString(result.dataType) {
        case "flt ":
            guard result.bytes.count >= 4 else { return nil }
            let bits = result.bytes.enumerated().reduce(UInt32(0)) { partial, item in
                partial | (UInt32(item.element) << (item.offset * 8))
            }
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard result.bytes.count >= 2 else { return nil }
            return Double(UInt16(result.bytes[0]) << 8 | UInt16(result.bytes[1])) / 4
        case "sp78":
            guard result.bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(result.bytes[0]) << 8 | UInt16(result.bytes[1]))) / 256
        case "ui8 ", "ui8", "ui16", "ui32":
            return result.bytes.reduce(Double(0)) { ($0 * 256) + Double($1) }
        default:
            return nil
        }
    }

    private static func temperatureName(for key: String) -> String {
        switch key {
        case "TB0T":
            return "Battery 0"
        case "TB1T":
            return "Battery 1"
        case "TB2T":
            return "Battery 2"
        case "TBAT":
            return "Battery"
        case "TG0P", "TG0D":
            return "GPU"
        default:
            return "CPU"
        }
    }
}

extension AppleSMCReadOnlyReader: BatteryTemperatureReading {
    func readBatteryTemperatureCelsius() -> Double? {
        guard case let .success(raw) = collect() else { return nil }
        return CoolingTemperaturePresentation.groups(raw.temperatures)
            .first(where: { $0.label == "Battery" })?
            .valueCelsius
    }
}
