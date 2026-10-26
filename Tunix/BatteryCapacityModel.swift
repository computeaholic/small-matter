import Foundation

enum BatteryCapacityModel {
    static func maximumCapacity(
        registry: [String: Any]?,
        batteryData: [String: Any]?
    ) -> Int? {
        valid(integer(registry?["AppleRawMaxCapacity"]))
            ?? valid(integer(batteryData?["FullChargeCapacity"]))
            ?? valid(integer(registry?["NominalChargeCapacity"]))
            ?? valid(integer(batteryData?["NominalChargeCapacity"]))
    }

    static func designCapacity(
        registry: [String: Any]?,
        batteryData: [String: Any]?
    ) -> Int? {
        valid(integer(registry?["DesignCapacity"]))
            ?? valid(integer(batteryData?["DesignCapacity"]))
    }

    static func capacities(
        registry: [String: Any]?,
        batteryData: [String: Any]?
    ) -> (maximum: Int?, design: Int?) {
        (
            maximum: maximumCapacity(registry: registry, batteryData: batteryData),
            design: designCapacity(registry: registry, batteryData: batteryData)
        )
    }

    static func valid(_ value: Int?) -> Int? {
        guard let value, value > 0, value < 65535 else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}
