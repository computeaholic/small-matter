/// Compatibility value retained for the existing pure charge-percentage tests.
/// Production UI reads one immutable `BatterySnapshot` instead.
struct BatteryStatus {
    var isPresent: Bool = false
    var isCharging: Bool = false
    var powerSource: String = "Unknown"
    var currentCapacity: Int = 0
    var maxCapacity: Int = 0
    var designCapacity: Int = 0
    var cycleCount: Int? = .none
    var voltage: Int = 0
    var amperage: Int = 0
    var hasVoltageReading = false
    var hasAmperageReading = false
}
