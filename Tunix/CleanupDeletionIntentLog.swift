import Foundation

struct CleanupDeletionIntent: Codable {
    let id: UUID
    let timestamp: Date
    let candidates: [CleanupCandidate]
    let completedCandidateIDs: [String]
}

final class CleanupDeletionIntentLog {
    private let intentURL: URL

    init(intentURL: URL? = nil) {
        if let intentURL {
            self.intentURL = intentURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let folder = appSupport.appendingPathComponent(
                ProductIdentity.stableApplicationSupportDirectoryName,
                isDirectory: true
            )
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.intentURL = folder.appendingPathComponent("cleanup-delete-intent.json")
        }
    }

    func write(_ intent: CleanupDeletionIntent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(intent).write(to: intentURL, options: .atomic)
    }

    func read() -> CleanupDeletionIntent? {
        guard let data = try? Data(contentsOf: intentURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CleanupDeletionIntent.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: intentURL)
    }
}
