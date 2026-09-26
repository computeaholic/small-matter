import Foundation
import OSLog

public enum TunixLogConfiguration {
    public static let smcDebugEnabled = true
    public static let rateLimitDebugEnabled = true
    public static let persistenceDebugEnabled = true
    public static let auditTrailEnabled = true
    public static let thermalMonitoringEnabled = true
}

public func loggedValue<T>(_ value: T, category: OSLog, message: String) -> T {
    os_log(
        "%{public}s: %{public}s",
        log: category,
        type: .debug,
        message,
        String(describing: value)
    )
    return value
}

public func loggedError<T>(_ error: Error, category: OSLog, message: String) throws -> T {
    os_log(
        "ERROR - %{public}s: %{public}s",
        log: category,
        type: .error,
        message,
        error.localizedDescription
    )
    throw error
}
