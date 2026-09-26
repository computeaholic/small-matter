import Foundation

/// Public-facing identity is centralized so product naming remains independent
/// from telemetry, persistence, and security architecture.
enum ProductIdentity {
    static let displayName = "Small Matter"
    static let shortName = "Small Matter"
    static let tagline = "Precise, read-only system telemetry for macOS."
    static let copyright = "© 2025 Tunix LLC"
    static let supportExportFilenameStem = "Small-Matter-Support-Snapshot"

    // These are deliberately stable storage identifiers. A public rebrand
    // must not strand existing settings, quarantine items, or ledgers.
    static let stableApplicationSupportDirectoryName = "Tunix"
    static let stableBundleIdentifier = "Tunix-LLC.Tunix"
    static let stableSubsystem = "com.tunix"
}
