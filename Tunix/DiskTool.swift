import AppKit
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
    @Published private(set) var selectedSupportedScope: String?
    @Published var lastError: String?
    @Published private(set) var hasInterruptedDeletion = false

    private let engine: SafeCleanupEngine
    private var roots: [CleanupRoot]
    private var securityScopedAccess: [String: SecurityScopedAccess] = [:]
    private let ledger: ActionLedger
    private let history: CleanupHistoryLog
    private let deletionIntentLog: CleanupDeletionIntentLog
    private let legacyIntentLog: CleanupIntentLog
    private var scanWorkItem: DispatchWorkItem?

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
        if isScanning {
            scanWorkItem?.cancel()
            return
        }
        guard !isDeleting else { return }
        isScanning = true
        lastError = nil
        let roots = self.roots
        let engine = engine
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            let result = engine.inventory(roots: roots, shouldCancel: { workItem.isCancelled })
            DispatchQueue.main.async {
                guard let self else { return }
                self.inventory = result
                self.selectedCandidateIDs = []
                self.lastScan = result.scannedAt
                self.isScanning = false
                self.scanWorkItem = nil
                if !result.isComplete {
                    self.lastError = "The scan was incomplete. Review the safety notice before scanning again."
                }
            }
        }
        scanWorkItem = workItem
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }

    func chooseXcodeDerivedDataLocation() {
        guard !isScanning, !isDeleting else { return }
        guard CleanupDistributionContext.current.allowsUserSelectedPermanentDeletion else {
            lastError =
                "The Mac App Store build does not enable permanent deletion of user-selected data. " +
                "No files were changed."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Xcode Derived Data"
        panel.prompt = "Review Derived Data"
        panel.message = "Choose the standard Xcode Derived Data folder. Arbitrary folders are not supported."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let suggestedLocation = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        if FileManager.default.fileExists(atPath: suggestedLocation.path) {
            panel.directoryURL = suggestedLocation
        }

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let root = SafeCleanupEngine.xcodeDerivedDataRoot(at: url) else {
                self?.lastError =
                    "Only the standard Library/Developer/Xcode/DerivedData folder is supported. No files were changed."
                return
            }

            let access = SecurityScopedAccess(url: root.url)
            if CleanupDistributionContext.current == .appStore, !access.granted {
                self?.lastError =
                    "macOS did not grant access to the selected Derived Data folder. No files were changed."
                return
            }

            DispatchQueue.main.async {
                self?.securityScopedAccess[root.id] = access
                self?.roots.removeAll { $0.id == root.id }
                self?.roots.append(root)
                self?.selectedSupportedScope = root.name
                self?.lastError = nil
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
              inventory.isComplete,
              !selectedCandidateIDs.isEmpty
        else { return }

        let selected = inventory.candidates.filter { selectedCandidateIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        if CleanupDistributionContext.current == .appStore,
           selected.contains(where: { candidate in
               self.roots.first(where: { $0.id == candidate.rootID })?.scope == .xcodeDerivedData
           }) {
            lastError =
                "The Mac App Store build does not enable permanent deletion of user-selected data. " +
                "No files were changed."
            return
        }
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
        let roots = self.roots
        DispatchQueue.global(qos: .utility).async {
            let result = engine.delete(candidates: selected, roots: roots)
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

    var selectedCandidates: [CleanupCandidate] {
        guard let inventory else { return [] }
        return inventory.candidates.filter { selectedCandidateIDs.contains($0.id) }
    }

    var selectedCandidateCount: Int {
        selectedCandidates.count
    }

    var selectedAllocatedBytes: UInt64 {
        selectedCandidates.reduce(0) { $0 + $1.allocatedBytes }
    }

    var selectedScopeDescription: String {
        let labels = Set(selectedCandidates.map(\.category)).sorted()
        return labels.isEmpty ? "no approved scope" : labels.joined(separator: ", ")
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

private final class SecurityScopedAccess {
    let granted: Bool
    private let url: URL

    init(url: URL) {
        self.url = url
        granted = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if granted {
            url.stopAccessingSecurityScopedResource()
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
