import Foundation

/// Intent log for crash recovery during cleanup operations
/// Ensures files are never lost even if app crashes mid-operation
struct CleanupIntent: Codable {
    let id: UUID
    let timestamp: Date
    let operations: [MoveOperation]

    struct MoveOperation: Codable {
        let source: String
        let destination: String
        let sizeBytes: UInt64
    }
}

final class CleanupIntentLog {
    private let intentURL: URL
    private let queue = DispatchQueue(label: "com.tunix.intentlog", qos: .utility)

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = appSupport.appendingPathComponent(
            ProductIdentity.stableApplicationSupportDirectoryName,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        intentURL = folder.appendingPathComponent("cleanup-intent.json")
    }

    func writeIntent(_ intent: CleanupIntent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(intent)
        try data.write(to: intentURL, options: .atomic)
    }

    func readIntent() -> CleanupIntent? {
        guard let data = try? Data(contentsOf: intentURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CleanupIntent.self, from: data)
    }

    func clearIntent() {
        try? FileManager.default.removeItem(at: intentURL)
    }

    /// Check for incomplete operations on startup and offer recovery
    func checkForIncompleteOperations() -> CleanupIntent? {
        guard let intent = readIntent() else { return nil }

        // Check if any operations are partially complete
        let hasIncomplete = intent.operations.contains { operation in
            let sourceExists = FileManager.default.fileExists(atPath: operation.source)
            let destExists = FileManager.default.fileExists(atPath: operation.destination)
            return !sourceExists && !destExists // File disappeared
        }

        return hasIncomplete ? intent : nil
    }
}
