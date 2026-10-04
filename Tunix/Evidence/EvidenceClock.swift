import Darwin
import Foundation

struct EvidenceClockReading: Equatable, Sendable {
    let wallTime: Date
    let continuousNanoseconds: UInt64?
    let processUptimeNanoseconds: UInt64?
    let bootSessionID: String?
    let clockDomainID: String
}

protocol EvidenceClock: Sendable {
    func reading() -> EvidenceClockReading
}

struct SystemEvidenceClock: EvidenceClock, Sendable {
    func reading() -> EvidenceClockReading {
        let uptime = ProcessInfo.processInfo.systemUptime
        let uptimeNanoseconds = uptime.isFinite && uptime >= 0
            ? UInt64(uptime * 1_000_000_000)
            : nil
        return EvidenceClockReading(
            wallTime: .now,
            continuousNanoseconds: Self.continuousNanoseconds(),
            processUptimeNanoseconds: uptimeNanoseconds,
            bootSessionID: Self.bootSessionID(),
            clockDomainID: "mach-continuous-time"
        )
    }

    private static func continuousNanoseconds() -> UInt64? {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS else { return nil }
        let ticks = mach_continuous_time()
        let nanos = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue
        guard timebase.denom != 0 else { return nil }
        return nanos / UInt64(timebase.denom)
    }

    private static func bootSessionID() -> String? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        let result = sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        guard result == 0 else { return nil }
        return "boot-(bootTime.tv_sec)-(bootTime.tv_usec)"
    }
}

struct FixedEvidenceClock: EvidenceClock, Sendable {
    private let value: EvidenceClockReading

    init(
        wallTime: Date,
        continuousNanoseconds: UInt64?,
        processUptimeNanoseconds: UInt64?,
        bootSessionID: String? = "fixed-boot",
        clockDomainID: String = "fixed-clock"
    ) {
        value = EvidenceClockReading(
            wallTime: wallTime,
            continuousNanoseconds: continuousNanoseconds,
            processUptimeNanoseconds: processUptimeNanoseconds,
            bootSessionID: bootSessionID,
            clockDomainID: clockDomainID
        )
    }

    func reading() -> EvidenceClockReading {
        value
    }
}
