import Foundation
import SwiftUI

final class DiskTool: ObservableObject {
    @Published private(set) var inventory: CleanupInventory?
    @Published var selectedCandidateIDs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isDeleting = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var lastResult: CleanupDeletionResult?
    @Published private(set) var lastAction: CleanupAction?
    @Published var lastError: String?
    @Published private(set) var hasInterruptedDeletion = false

    private let engine: SafeCleanupEngine
    private let roots: [CleanupRoot]
    private let ledger: ActionLedger
    private let history: CleanupHistoryLog
    private let deletionIntentLog: CleanupDeletionIntentLog
    private let legacyIntentLog: CleanupIntentLog

    init(
        storage: any CleanupStorage = LocalCleanupStorage(),
        roots: [CleanupRoot]? = nil,
        ledgerURL: URL? = nil,
        historyURL: URL? = nil,
        deletionIntentURL: URL? = nil
    ) {
        engine = SafeCleanupEngine(storage: storage)
        self.roots = roots ?? SafeCleanupEngine.defaultRoots()
        ledger = ActionLedger(ledgerURL: ledgerURL)
        history = CleanupHistoryLog(historyURL: historyURL)
        deletionIntentLog = CleanupDeletionIntentLog(intentURL: deletionIntentURL)
        legacyIntentLog = CleanupIntentLog()
        lastAction = ledger.last()

        if legacyIntentLog.checkForIncompleteOperations() != nil {
            lastError = "An earlier quarantine operation needs review. Existing files were not changed."
        }
        if deletionIntentLog.read() != nil {
            hasInterruptedDeletion = true
            lastError = "An earlier deletion was interrupted. Scan again; no automatic rollback was attempted."
        }
    }

    func scan() {
        guard !isScanning, !isDeleting else { return }
        isScanning = true
        lastError = nil
        let roots = roots
        let engine = engine
        DispatchQueue.global(qos: .utility).async {
            let result = engine.inventory(roots: roots)
            DispatchQueue.main.async {
                self.inventory = result
                self.selectedCandidateIDs = Set(result.candidates.map(\.id))
                self.lastScan = result.scannedAt
                self.isScanning = false
            }
        }
    }

    func isSelected(_ candidate: CleanupCandidate) -> Bool {
        selectedCandidateIDs.contains(candidate.id)
    }

    func setSelected(_ candidate: CleanupCandidate, isSelected: Bool) {
        if isSelected {
            selectedCandidateIDs.insert(candidate.id)
        } else {
            selectedCandidateIDs.remove(candidate.id)
        }
    }

    func deleteSelected() {
        guard !isDeleting,
              let inventory,
              !selectedCandidateIDs.isEmpty
        else { return }

        let selected = inventory.candidates.filter { selectedCandidateIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        isDeleting = true
        lastError = nil
        let intent = CleanupDeletionIntent(
            id: UUID(),
            timestamp: .now,
            candidates: selected,
            completedCandidateIDs: []
        )
        do {
            try deletionIntentLog.write(intent)
        } catch {
            isDeleting = false
            lastError = "Unable to prepare a verified deletion. No files were changed."
            return
        }

        let engine = engine
        DispatchQueue.global(qos: .utility).async {
            let result = engine.delete(candidates: selected)
            self.history.append(result)
            self.deletionIntentLog.clear()
            DispatchQueue.main.async {
                self.lastResult = result
                self.inventory = engine.inventory(roots: self.roots)
                self.selectedCandidateIDs = []
                self.isDeleting = false
                if result.failedCount > 0 || result.staleCount > 0 {
                    self.lastError = self.failureSummary(for: result)
                }
            }
        }
    }

    func undoLastAction() {
        guard !isDeleting, let action = ledger.last() else { return }
        lastError = nil

        DispatchQueue.global(qos: .utility).async {
            let outcome = Self.restore(action)
            let unresolvedItems = action.items.filter { !outcome.restoredIDs.contains($0.id) }
            let updatedAction = CleanupAction(
                id: action.id,
                date: action.date,
                targets: action.targets,
                totalBytes: unresolvedItems.reduce(0) { $0 + $1.sizeBytes },
                items: unresolvedItems
            )
            if unresolvedItems.isEmpty {
                _ = self.ledger.removeLast(ifMatching: action.id)
            } else {
                self.ledger.replaceLast(updatedAction)
            }

            DispatchQueue.main.async {
                self.lastAction = self.ledger.last()
                if !outcome.errors.isEmpty {
                    self.lastError = outcome.errors.joined(separator: " ")
                }
                self.scan()
            }
        }
    }
}

private extension DiskTool {
    struct RestoreOutcome {
        let restoredIDs: Set<UUID>
        let errors: [String]
    }

    static func restore(_ action: CleanupAction) -> RestoreOutcome {
        var restoredIDs = Set<UUID>()
        var errors: [String] = []

        for item in action.items {
            let originalURL = URL(fileURLWithPath: item.originalPath)
            let quarantineURL = URL(fileURLWithPath: item.quarantinePath)
            guard FileManager.default.fileExists(atPath: quarantineURL.path) else {
                errors.append("Could not restore one item because its quarantine copy is missing.")
                continue
            }
            if FileManager.default.fileExists(atPath: originalURL.path) {
                errors.append("Could not restore one item because its original destination is occupied.")
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: originalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: quarantineURL, to: originalURL)
                restoredIDs.insert(item.id)
            } catch {
                errors.append("Could not restore one item; it remains in quarantine.")
            }
        }
        return RestoreOutcome(restoredIDs: restoredIDs, errors: errors)
    }

    func failureSummary(for result: CleanupDeletionResult) -> String {
        let parts = [
            result.failedCount > 0 ? "\(result.failedCount) deletion failed" : nil,
            result.staleCount > 0 ? "\(result.staleCount) changed or disappeared before deletion" : nil
        ].compactMap { $0 }
        return parts.joined(separator: "; ") + ". No failed item is reported as deleted."
    }
}
