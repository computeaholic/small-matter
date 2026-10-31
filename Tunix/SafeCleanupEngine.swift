import Foundation

private struct CleanupRootInventory {
    var scannedItemCount = 0
    var candidates: [CleanupCandidate] = []
    var skippedByReason: [CleanupSkipReason: Int] = [:]
}

struct SafeCleanupEngine {
    let storage: any CleanupStorage
    private let activeDevelopmentProcessNames: () -> [String]

    init(
        storage: any CleanupStorage = LocalCleanupStorage(),
        activeDevelopmentProcessNames: @escaping () -> [String] = LocalCleanupStorage.activeDevelopmentProcessNames
    ) {
        self.storage = storage
        self.activeDevelopmentProcessNames = activeDevelopmentProcessNames
    }

    func inventory(
        roots: [CleanupRoot],
        distribution: CleanupDistributionContext = .current,
        now: Date = .now
    ) -> CleanupInventory {
        let rootInventories = roots.map { inventory(root: $0) }
        let candidates = rootInventories.flatMap(\.candidates)
        let scannedItemCount = rootInventories.reduce(0) { $0 + $1.scannedItemCount }
        let skippedByReason = rootInventories.reduce(into: [CleanupSkipReason: Int]()) { partial, result in
            for (reason, count) in result.skippedByReason {
                partial[reason, default: 0] += count
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

    private func inventory(root: CleanupRoot) -> CleanupRootInventory {
        let standardizedRoot = root.url.standardizedFileURL
        guard !standardizedRoot.path.isEmpty,
              standardizedRoot.resolvingSymlinksInPath().standardizedFileURL.path == standardizedRoot.path
        else {
            return CleanupRootInventory(skippedByReason: [.outsideApprovedScope: 1])
        }
        guard storage.exists(at: root.url) else { return CleanupRootInventory() }
        if root.scope == .xcodeDerivedData,
           !activeDevelopmentProcessNames().isEmpty {
            return CleanupRootInventory(skippedByReason: [.activeDevelopmentProcess: 1])
        }

        let items: [URL]
        do {
            items = try storage.enumerateItems(at: root.url)
        } catch {
            return CleanupRootInventory(skippedByReason: [.metadataUnavailable: 1])
        }
        return inventory(items: items, root: root)
    }

    private func inventory(items: [URL], root: CleanupRoot) -> CleanupRootInventory {
        var result = CleanupRootInventory()
        for item in items {
            result.scannedItemCount += 1
            guard isDescendant(item, of: root.url) else {
                result.skippedByReason[.outsideApprovedScope, default: 0] += 1
                continue
            }
            guard let metadata = try? storage.metadata(for: item) else {
                result.skippedByReason[.metadataUnavailable, default: 0] += 1
                continue
            }
            switch decision(for: item, metadata: metadata, root: root) {
            case let .candidate(candidate):
                result.candidates.append(candidate)
            case let .skip(reason):
                result.skippedByReason[reason, default: 0] += 1
            }
        }
        return result
    }

    func delete(
        candidates: [CleanupCandidate],
        roots: [CleanupRoot] = [],
        beforeEachDelete: ((CleanupCandidate) -> Void)? = nil,
        now: Date = .now
    ) -> CleanupDeletionResult {
        let selected = candidates.filter { $0.access == .eligible }
        let referenceURL = URL(fileURLWithPath: selected.first?.path ?? NSTemporaryDirectory())
        let availableBefore = storage.availableBytes(at: referenceURL)
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        var deletedCount = 0
        var staleCount = 0
        var failedCount = 0
        var diagnostics: [CleanupDiagnostic] = []

        for candidate in selected {
            switch delete(
                candidate: candidate,
                root: rootsByID[candidate.rootID],
                beforeEachDelete: beforeEachDelete
            ) {
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
        root: CleanupRoot?,
        beforeEachDelete: ((CleanupCandidate) -> Void)?
    ) -> CandidateDeletionOutcome {
        let url = URL(fileURLWithPath: candidate.path)
        guard storage.exists(at: url) else { return .stale("No longer present") }
        if let root {
            guard isCanonicalDescendant(url, of: root) else {
                return .stale("Path changed outside approved scope")
            }
            if root.scope == .xcodeDerivedData,
               !activeDevelopmentProcessNames().isEmpty {
                return .stale("Active development process detected")
            }
        }
        guard let current = try? storage.metadata(for: url),
              current.fingerprint == candidate.fingerprint
        else { return .stale("Changed after scan") }

        beforeEachDelete?(candidate)
        if let root {
            guard isCanonicalDescendant(url, of: root) else {
                return .stale("Path changed outside approved scope")
            }
            if root.scope == .xcodeDerivedData,
               !activeDevelopmentProcessNames().isEmpty {
                return .stale("Active development process detected")
            }
        }
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

    private func isCanonicalDescendant(_ item: URL, of root: CleanupRoot) -> Bool {
        let standardizedRoot = root.url.standardizedFileURL
        let standardizedItem = item.standardizedFileURL
        guard standardizedRoot.resolvingSymlinksInPath().standardizedFileURL.path == standardizedRoot.path,
              isDescendant(standardizedItem, of: standardizedRoot),
              standardizedItem.resolvingSymlinksInPath().standardizedFileURL.path == standardizedItem.path
        else { return false }
        return true
    }
}
