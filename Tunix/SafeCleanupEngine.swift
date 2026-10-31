import Foundation

private struct CleanupRootInventory {
    var scannedItemCount = 0
    var candidates: [CleanupCandidate] = []
    var skippedByReason: [CleanupSkipReason: Int] = [:]
    var isComplete = true
}

private struct CleanupDeletionAccounting {
    var deletedCount = 0
    var staleCount = 0
    var failedCount = 0
    var diagnostics: [CleanupDiagnostic] = []
}

struct SafeCleanupEngine {
    let storage: any CleanupStorage
    let developmentProcessSnapshot: () -> DevelopmentProcessSnapshot

    init(
        storage: any CleanupStorage = LocalCleanupStorage(),
        developmentProcessSnapshot: @escaping () -> DevelopmentProcessSnapshot =
            LocalCleanupStorage.activeDevelopmentProcessSnapshot
    ) {
        self.storage = storage
        self.developmentProcessSnapshot = developmentProcessSnapshot
    }

    func inventory(
        roots: [CleanupRoot],
        distribution: CleanupDistributionContext = .current,
        now: Date = .now,
        maxItemsPerRoot: Int = 50000,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> CleanupInventory {
        var rootInventories: [CleanupRootInventory] = []
        for root in roots {
            let rootInventory = inventory(
                root: root,
                maxItems: maxItemsPerRoot,
                shouldCancel: shouldCancel
            )
            rootInventories.append(rootInventory)
            if !rootInventory.isComplete,
               rootInventory.skippedByReason[.scanCancelled] != nil {
                break
            }
        }
        let candidates = rootInventories.flatMap(\.candidates)
        let scannedItemCount = rootInventories.reduce(0) { $0 + $1.scannedItemCount }
        let isComplete = rootInventories.allSatisfy(\.isComplete)
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
            scannedAt: now,
            isComplete: isComplete
        )
    }

    private func inventory(
        root: CleanupRoot,
        maxItems: Int,
        shouldCancel: () -> Bool
    ) -> CleanupRootInventory {
        let standardizedRoot = root.url.standardizedFileURL
        guard !standardizedRoot.path.isEmpty,
              standardizedRoot.resolvingSymlinksInPath().standardizedFileURL.path == standardizedRoot.path
        else {
            return CleanupRootInventory(skippedByReason: [.outsideApprovedScope: 1], isComplete: false)
        }
        guard storage.exists(at: root.url) else { return CleanupRootInventory() }
        guard let rootMetadata = try? storage.metadata(for: root.url),
              rootMetadata.isDirectory,
              !rootMetadata.isSymbolicLink,
              let rootResourceIdentifier = rootMetadata.resourceIdentifier
        else {
            return CleanupRootInventory(skippedByReason: [.metadataUnavailable: 1], isComplete: false)
        }
        if root.scope == .xcodeDerivedData {
            let processSnapshot = developmentProcessSnapshot()
            guard processSnapshot.isComplete else {
                return CleanupRootInventory(
                    skippedByReason: [.processDetectionUnavailable: 1],
                    isComplete: false
                )
            }
            guard processSnapshot.names.isEmpty else {
                return CleanupRootInventory(skippedByReason: [.activeDevelopmentProcess: 1])
            }
        }

        let enumeration: CleanupEnumerationResult
        do {
            enumeration = try storage.enumerateItems(
                at: root.url,
                limit: maxItems,
                shouldCancel: shouldCancel
            )
        } catch {
            return CleanupRootInventory(skippedByReason: [.metadataUnavailable: 1], isComplete: false)
        }
        var result = inventory(
            items: enumeration.items,
            root: root,
            rootResourceIdentifier: rootResourceIdentifier
        )
        if enumeration.reachedLimit {
            result.skippedByReason[.inventoryLimitReached, default: 0] += 1
            result.isComplete = false
        }
        if enumeration.wasCancelled {
            result.skippedByReason[.scanCancelled, default: 0] += 1
            result.isComplete = false
        }
        return result
    }

    private func inventory(
        items: [URL],
        root: CleanupRoot,
        rootResourceIdentifier: String
    ) -> CleanupRootInventory {
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
            guard sameFileSystem(metadata.resourceIdentifier, rootResourceIdentifier) else {
                result.skippedByReason[.outsideApprovedScope, default: 0] += 1
                continue
            }
            switch decision(
                for: item,
                metadata: metadata,
                root: root,
                rootResourceIdentifier: rootResourceIdentifier
            ) {
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
        roots: [CleanupRoot],
        beforeEachDelete: ((CleanupCandidate) -> Void)? = nil,
        now: Date = .now
    ) -> CleanupDeletionResult {
        let selected = candidates.filter { $0.access == .eligible }
        let referenceURL = URL(fileURLWithPath: selected.first?.path ?? NSTemporaryDirectory())
        let availableBefore = storage.availableBytes(at: referenceURL)
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let accounting = deleteSelectedCandidates(
            selected,
            rootsByID: rootsByID,
            beforeEachDelete: beforeEachDelete
        )

        let availableAfter = storage.availableBytes(at: referenceURL)

        return CleanupDeletionResult(
            scannedItemCount: selected.count,
            attemptedCount: selected.count,
            deletedCount: accounting.deletedCount,
            staleCount: accounting.staleCount,
            failedCount: accounting.failedCount,
            estimatedAllocatedBytes: selected.reduce(0) { $0 + $1.allocatedBytes },
            observedSpaceReclaimedBytes: observedSpaceReclaimed(before: availableBefore, after: availableAfter),
            availableBytesBefore: availableBefore,
            availableBytesAfter: availableAfter,
            diagnostics: accounting.diagnostics,
            completedAt: now
        )
    }

    private func deleteSelectedCandidates(
        _ candidates: [CleanupCandidate],
        rootsByID: [String: CleanupRoot],
        beforeEachDelete: ((CleanupCandidate) -> Void)?
    ) -> CleanupDeletionAccounting {
        var accounting = CleanupDeletionAccounting()
        for candidate in candidates {
            guard let root = rootsByID[candidate.rootID] else {
                accounting.staleCount += 1
                accounting.diagnostics.append(
                    CleanupDiagnostic(category: candidate.category, reason: "Approved root unavailable", count: 1)
                )
                continue
            }
            switch delete(candidate: candidate, root: root, beforeEachDelete: beforeEachDelete) {
            case .deleted:
                accounting.deletedCount += 1
            case let .stale(reason):
                accounting.staleCount += 1
                accounting.diagnostics.append(
                    CleanupDiagnostic(category: candidate.category, reason: reason, count: 1)
                )
            case let .failed(reason):
                accounting.failedCount += 1
                accounting.diagnostics.append(
                    CleanupDiagnostic(category: candidate.category, reason: reason, count: 1)
                )
            }
        }
        return accounting
    }

    private enum InventoryDecision {
        case candidate(CleanupCandidate)
        case skip(CleanupSkipReason)
    }

    private func decision(
        for item: URL,
        metadata: CleanupFileMetadata,
        root: CleanupRoot,
        rootResourceIdentifier: String
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
                approvedRootResourceIdentifier: rootResourceIdentifier,
                access: .eligible,
                exclusionReason: nil,
                fingerprint: metadata.fingerprint
            )
        )
    }
}
