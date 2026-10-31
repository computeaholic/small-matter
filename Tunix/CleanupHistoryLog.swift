import Foundation

final class CleanupHistoryLog {
    private let historyURL: URL
    private var records: [CleanupDeletionRecord] = []

    init(historyURL: URL? = nil) {
        if let historyURL {
            self.historyURL = historyURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let folder = appSupport.appendingPathComponent(
                ProductIdentity.stableApplicationSupportDirectoryName,
                isDirectory: true
            )
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.historyURL = folder.appendingPathComponent("cleanup-history.json")
        }
        load()
    }

    var latest: CleanupDeletionRecord? {
        records.last
    }

    func append(_ result: CleanupDeletionResult) {
        records.append(
            CleanupDeletionRecord(
                id: UUID(),
                date: result.completedAt,
                deletedCount: result.deletedCount,
                failedCount: result.failedCount,
                staleCount: result.staleCount,
                estimatedAllocatedBytes: result.estimatedAllocatedBytes,
                observedSpaceReclaimedBytes: result.observedSpaceReclaimedBytes
            )
        )
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder.iso8601.decode([CleanupDeletionRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder.iso8601.encode(records) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
