import Foundation

protocol CleanupStorage {
    func enumerateItems(at root: URL) throws -> [URL]
    func metadata(for url: URL) throws -> CleanupFileMetadata
    func exists(at url: URL) -> Bool
    func deleteItem(at url: URL) throws
    func availableBytes(at url: URL) -> UInt64?
}

struct LocalCleanupStorage: CleanupStorage {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func enumerateItems(at root: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CleanupStorageError.rootIsNotDirectory
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isReadableKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }

    func metadata(for url: URL) throws -> CleanupFileMetadata {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ])
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let logicalBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let allocatedBytes = UInt64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? Int(logicalBytes)
        )
        let resourceIdentifier = attributes[.systemFileNumber].map { String(describing: $0) }
        let identity = "\(url.standardizedFileURL.path)#\(resourceIdentifier ?? "path")"
        let hardLinkCount = (attributes[.referenceCount] as? NSNumber)?.uint64Value ?? 1
        let isSymbolicLink = (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
        return CleanupFileMetadata(
            identity: identity,
            path: url.standardizedFileURL.path,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            modificationDate: attributes[.modificationDate] as? Date,
            resourceIdentifier: resourceIdentifier,
            isDirectory: values.isDirectory ?? ((attributes[.type] as? FileAttributeType) == .typeDirectory),
            isSymbolicLink: isSymbolicLink,
            hardLinkCount: hardLinkCount,
            isReadable: fileManager.isReadableFile(atPath: url.path),
            isWritable: fileManager.isWritableFile(atPath: url.path)
        )
    }

    func exists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func deleteItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func availableBytes(at url: URL) -> UInt64? {
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: url.path),
              let freeBytes = attributes[.systemFreeSize] as? NSNumber
        else { return nil }
        return freeBytes.uint64Value
    }
}

enum CleanupStorageError: Error, Equatable {
    case rootIsNotDirectory
    case metadataUnavailable
}

struct SafeCleanupEngine {
    let storage: any CleanupStorage

    init(storage: any CleanupStorage = LocalCleanupStorage()) {
        self.storage = storage
    }

    static func defaultRoots(fileManager: FileManager = .default) -> [CleanupRoot] {
        let cacheRoot = (fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory)
            .appendingPathComponent(ProductIdentity.stableBundleIdentifier, isDirectory: true)
        return [
            CleanupRoot(
                id: "small-matter-owned-cache",
                name: "Small Matter disposable cache",
                url: cacheRoot,
                explanation: "Only Small Matter-owned disposable cache files are considered."
            )
        ]
    }

    func inventory(
        roots: [CleanupRoot],
        distribution: CleanupDistributionContext = .current,
        now: Date = .now
    ) -> CleanupInventory {
        var candidates: [CleanupCandidate] = []
        var skippedByReason: [CleanupSkipReason: Int] = [:]
        var scannedItemCount = 0

        for root in roots {
            let standardizedRoot = root.url.standardizedFileURL
            guard !standardizedRoot.path.isEmpty,
                  standardizedRoot.resolvingSymlinksInPath().standardizedFileURL.path == standardizedRoot.path else {
                skippedByReason[.outsideApprovedScope, default: 0] += 1
                continue
            }

            guard storage.exists(at: root.url) else { continue }
            let items: [URL]
            do {
                items = try storage.enumerateItems(at: root.url)
            } catch {
                skippedByReason[.metadataUnavailable, default: 0] += 1
                continue
            }

            for item in items {
                scannedItemCount += 1
                guard isDescendant(item, of: root.url) else {
                    skippedByReason[.outsideApprovedScope, default: 0] += 1
                    continue
                }

                let metadata: CleanupFileMetadata
                do {
                    metadata = try storage.metadata(for: item)
                } catch {
                    skippedByReason[.metadataUnavailable, default: 0] += 1
                    continue
                }

                switch decision(for: item, metadata: metadata, root: root) {
                case let .candidate(candidate):
                    candidates.append(candidate)
                case let .skip(reason):
                    skippedByReason[reason, default: 0] += 1
                }
            }
        }

        let skipped = skippedByReason
            .map { CleanupSkipSummary(reason: $0.key, count: $0.value) }
            .sorted { $0.reason.rawValue < $1.reason.rawValue }
        return CleanupInventory(
            scannedItemCount: scannedItemCount,
            candidates: candidates.sorted { $0.path < $1.path },
            skipped: skipped,
            roots: roots,
            distribution: distribution,
            scannedAt: now
        )
    }

    func delete(
        candidates: [CleanupCandidate],
        beforeEachDelete: ((CleanupCandidate) -> Void)? = nil,
        now: Date = .now
    ) -> CleanupDeletionResult {
        let selected = candidates.filter { $0.access == .eligible }
        let referenceURL = URL(fileURLWithPath: selected.first?.path ?? NSTemporaryDirectory())
        let availableBefore = storage.availableBytes(at: referenceURL)
        var deletedCount = 0
        var staleCount = 0
        var failedCount = 0
        var diagnostics: [CleanupDiagnostic] = []

        for candidate in selected {
            switch delete(candidate: candidate, beforeEachDelete: beforeEachDelete) {
            case .deleted:
                deletedCount += 1
            case let .stale(reason):
                staleCount += 1
                diagnostics.append(CleanupDiagnostic(category: candidate.category, reason: reason, count: 1))
            case let .failed(reason):
                failedCount += 1
                diagnostics.append(CleanupDiagnostic(category: candidate.category, reason: reason, count: 1))
            }
        }

        let availableAfter = storage.availableBytes(at: referenceURL)
        let observedReclaimed: UInt64?
        if let availableBefore, let availableAfter, availableAfter > availableBefore {
            observedReclaimed = availableAfter - availableBefore
        } else if availableBefore != nil, availableAfter != nil {
            observedReclaimed = 0
        } else {
            observedReclaimed = nil
        }

        return CleanupDeletionResult(
            scannedItemCount: selected.count,
            attemptedCount: selected.count,
            deletedCount: deletedCount,
            staleCount: staleCount,
            failedCount: failedCount,
            estimatedAllocatedBytes: selected.reduce(0) { $0 + $1.allocatedBytes },
            observedSpaceReclaimedBytes: observedReclaimed,
            availableBytesBefore: availableBefore,
            availableBytesAfter: availableAfter,
            diagnostics: diagnostics,
            completedAt: now
        )
    }

    private enum InventoryDecision {
        case candidate(CleanupCandidate)
        case skip(CleanupSkipReason)
    }

    private enum CandidateDeletionOutcome {
        case deleted
        case stale(String)
        case failed(String)
    }

    private func decision(
        for item: URL,
        metadata: CleanupFileMetadata,
        root: CleanupRoot
    ) -> InventoryDecision {
        if metadata.isSymbolicLink {
            return .skip(.symbolicLink)
        }
        if metadata.isDirectory {
            return .skip(.directory)
        }
        if item.lastPathComponent.hasPrefix(".") {
            return .skip(.hidden)
        }
        if metadata.hardLinkCount > 1 {
            return .skip(.hardLink)
        }
        if !metadata.isReadable {
            return .skip(.unreadable)
        }
        if !metadata.isWritable {
            return .skip(.unwritable)
        }
        return .candidate(
            CleanupCandidate(
                id: metadata.identity,
                rootID: root.id,
                category: root.name,
                path: metadata.path,
                displayName: item.lastPathComponent,
                logicalBytes: metadata.logicalBytes,
                allocatedBytes: metadata.allocatedBytes,
                evidence: root.explanation,
                access: .eligible,
                exclusionReason: nil,
                fingerprint: metadata.fingerprint
            )
        )
    }

    private func delete(
        candidate: CleanupCandidate,
        beforeEachDelete: ((CleanupCandidate) -> Void)?
    ) -> CandidateDeletionOutcome {
        let url = URL(fileURLWithPath: candidate.path)
        guard storage.exists(at: url) else { return .stale("No longer present") }
        guard let current = try? storage.metadata(for: url),
              current.fingerprint == candidate.fingerprint
        else { return .stale("Changed after scan") }

        beforeEachDelete?(candidate)
        guard let revalidated = try? storage.metadata(for: url),
              revalidated.fingerprint == candidate.fingerprint
        else { return .stale("Changed before deletion") }

        do {
            try storage.deleteItem(at: url)
            return storage.exists(at: url)
                ? .failed("Deletion could not be verified")
                : .deleted
        } catch {
            return .failed("Permission or filesystem failure")
        }
    }

    private func isDescendant(_ item: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let itemPath = item.standardizedFileURL.path
        return itemPath.hasPrefix(rootPath + "/")
    }
}

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
