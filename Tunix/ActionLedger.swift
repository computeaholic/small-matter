import Foundation

struct CleanupItem: Codable, Identifiable {
    let id: UUID
    let originalPath: String
    let quarantinePath: String
    let sizeBytes: UInt64
}

struct CleanupAction: Codable, Identifiable {
    let id: UUID
    let date: Date
    let targets: [String]
    let totalBytes: UInt64
    let items: [CleanupItem]
}

final class ActionLedger {
    private var actions: [CleanupAction] = []
    private let queue = DispatchQueue(label: "com.tunix.actionledger", qos: .utility)
    private let ledgerURL: URL

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
        ledgerURL = folder.appendingPathComponent("action-ledger.json")
        load()
    }

    func append(_ action: CleanupAction) {
        queue.async(flags: .barrier) {
            self.actions.append(action)
            self.save()
        }
    }

    func popLast() -> CleanupAction? {
        var result: CleanupAction?
        queue.sync(flags: .barrier) {
            guard !self.actions.isEmpty else { return }
            result = self.actions.removeLast()
            self.save()
        }
        return result
    }

    func last() -> CleanupAction? {
        queue.sync {
            self.actions.last
        }
    }

    func all() -> [CleanupAction] {
        queue.sync {
            self.actions
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: ledgerURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([CleanupAction].self, from: data) {
            actions = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(actions) {
            try? data.write(to: ledgerURL)
        }
    }
}
