import Foundation
import OSLog

/// Structured logging categories for read-only telemetry and persistence.
public enum TunixLogging {
    public static let smc = OSLog(
        subsystem: "com.tunix",
        category: "smc"
    )

    public static let rateLimit = OSLog(
        subsystem: "com.tunix",
        category: "rate-limit"
    )

    public static let persistence = OSLog(
        subsystem: "com.tunix",
        category: "persistence"
    )

    public static let thermal = OSLog(
        subsystem: "com.tunix",
        category: "thermal"
    )
}

public enum PersistenceLogging {
    public static func logFileWrite(_ filename: String, size: Int, synced: Bool) {
        let syncStatus = synced ? "synced" : "buffered"
        os_log(
            "File write: %{public}s [%d bytes, %{public}s]",
            log: TunixLogging.persistence,
            type: .debug,
            filename,
            size,
            syncStatus
        )
    }

    public static func logFileSync(_ filename: String, duration: TimeInterval) {
        os_log(
            "File sync: %{public}s [%f ms]",
            log: TunixLogging.persistence,
            type: .debug,
            filename,
            duration * 1000
        )
    }

    public static func logStateRestoration(_ item: String, success: Bool) {
        os_log(
            "State restoration: %{public}s [%{public}s]",
            log: TunixLogging.persistence,
            type: success ? .debug : .default,
            item,
            success ? "success" : "failed"
        )
    }
}
