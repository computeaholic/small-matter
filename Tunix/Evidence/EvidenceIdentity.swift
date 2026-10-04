import Foundation

enum EvidenceSubjectType: String, Codable, Equatable, Sendable {
    case display = "DISPLAY"
    case storageDisk = "STORAGE_DISK"
    case mountedVolume = "MOUNTED_VOLUME"
    case networkInterface = "NETWORK_INTERFACE"
    case powerSource = "POWER_SOURCE"
    case sleepWakeBoundary = "SLEEP_WAKE_BOUNDARY"
    case thermal = "THERMAL"
    case usbDevice = "USB_DEVICE"
    case systemContext = "SYSTEM_CONTEXT"
    case unknown = "UNKNOWN"
}

enum EvidenceIdentityQuality: String, Codable, Equatable, Sendable {
    case provenStable = "PROVEN_STABLE"
    case qualified = "QUALIFIED"
    case transientRunLocal = "TRANSIENT_RUN_LOCAL"
    case weak = "WEAK"
    case unavailable = "UNAVAILABLE"
    case unknown = "UNKNOWN"
}

struct EvidenceSubject: Codable, Equatable, Sendable {
    let type: EvidenceSubjectType
    /// A redacted digest or other qualified identifier; never a raw serial, MAC, SSID, username, or path.
    let identityDigest: String?
    let quality: EvidenceIdentityQuality
    let safeDisplayLabel: String?
}
