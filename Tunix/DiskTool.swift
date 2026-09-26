import SwiftUI

private struct PlannedDiskCleanupTarget {
    let target: DiskCleanupTarget
    let quarantineURL: URL
    let plannedMoves: [CleanupIntent.MoveOperation]
}

private struct DiskCleanupPlan {
    let id: UUID
    let timestamp: Date
    let targets: [PlannedDiskCleanupTarget]

    var intent: CleanupIntent {
        CleanupIntent(
            id: id,
            timestamp: timestamp,
            operations: targets.flatMap(\.plannedMoves)
        )
    }
}

private struct CleanupExecutionResult {
    let action: CleanupAction
    let errors: [String]
}

struct DiskCleanupTarget: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    var isEnabled: Bool = true
    var sizeBytes: UInt64?
    var fileCount: Int?
}

final class DiskTool: ObservableObject {
    @Published var targets: [DiskCleanupTarget] = DiskTool.defaultTargets()
    @Published var isScanning = false
    @Published var isStaging = false
    @Published var lastScan: Date?
    @Published var lastAction: CleanupAction?
    @Published var lastError: String?

    private let ledger = ActionLedger()
    private let intentLog = CleanupIntentLog()
    private let safeAllowedPaths: Set<String> = ["~/Library/Caches", "~/Library/Logs", "/tmp", "/private/var/tmp"]

    init() {
        lastAction = ledger.last()

        // Check for incomplete operations on startup
        if let incompleteOps = intentLog.checkForIncompleteOperations() {
            lastError = "⚠️ Incomplete cleanup detected: \(incompleteOps.operations.count) " +
                "operations from \(incompleteOps.timestamp). Files may be in " +
                "the legacy-compatible path ~/Library/Application Support/Tunix/Quarantine. " +
                "Review and restore if needed."
        }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let expanded = targets

        DispatchQueue.global(qos: .utility).async {
            let updated = expanded.map { target -> DiskCleanupTarget in
                var target = target
                let path = (target.path as NSString).expandingTildeInPath
                let result = Self.directoryStats(at: path)
                target.sizeBytes = result.size
                target.fileCount = result.count
                return target
            }

            DispatchQueue.main.async {
                self.targets = updated
                self.isScanning = false
                self.lastScan = .now
            }
        }
    }

    func stageCleanup(safeMode: Bool) {
        guard !isStaging else { return }
        lastError = nil
        isStaging = true

        let selectedTargets = allowedTargets(for: safeMode).filter(\.isEnabled)

        DispatchQueue.global(qos: .utility).async {
            let plan = self.buildCleanupPlan(for: selectedTargets)

            do {
                try self.intentLog.writeIntent(plan.intent)
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "Failed to write cleanup intent: \(error.localizedDescription)"
                    self.isStaging = false
                }
                return
            }

            let result = self.executeCleanup(plan)

            DispatchQueue.main.async {
                self.ledger.append(result.action)
                self.lastAction = result.action
                self.isStaging = false
                if !result.errors.isEmpty {
                    self.lastError = result.errors.joined(separator: "\n")
                }
                self.intentLog.clearIntent()
                self.scan()
            }
        }
    }

    func undoLastAction() {
        guard let action = ledger.popLast() else { return }
        lastError = nil

        DispatchQueue.global(qos: .utility).async {
            var errors: [String] = []
            for item in action.items {
                let originalURL = URL(fileURLWithPath: item.originalPath)
                let quarantineURL = URL(fileURLWithPath: item.quarantinePath)
                let parent = originalURL.deletingLastPathComponent()
                do {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: originalURL.path) {
                        errors.append("Skip restore, exists: \(originalURL.path)")
                        continue
                    }
                    try FileManager.default.moveItem(at: quarantineURL, to: originalURL)
                } catch {
                    errors.append("Failed to restore \(originalURL.path)")
                }
            }

            DispatchQueue.main.async {
                self.lastAction = self.ledger.last()
                if !errors.isEmpty {
                    self.lastError = errors.joined(separator: "\n")
                }
                self.scan()
            }
        }
    }
}

private extension DiskTool {
    static func directoryStats(at path: String) -> (size: UInt64, count: Int) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return (0, 0)
        }

        let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var total: UInt64 = 0
        var count = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            )
            if let fileSize = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize {
                total += UInt64(fileSize)
                count += 1
            }
        }
        return (total, count)
    }

    func buildCleanupPlan(for targets: [DiskCleanupTarget]) -> DiskCleanupPlan {
        let timestamp = Date()
        let quarantineRoot = Self.quarantineRoot().appendingPathComponent(
            ISO8601DateFormatter().string(from: timestamp),
            isDirectory: true
        )
        let plannedTargets = targets.map { target in
            buildCleanupTargetPlan(for: target, quarantineRoot: quarantineRoot)
        }
        return DiskCleanupPlan(id: UUID(), timestamp: timestamp, targets: plannedTargets)
    }

    func buildCleanupTargetPlan(
        for target: DiskCleanupTarget,
        quarantineRoot: URL
    ) -> PlannedDiskCleanupTarget {
        let sourceURL = URL(fileURLWithPath: (target.path as NSString).expandingTildeInPath)
        let targetFolderName = target.name.replacingOccurrences(of: " ", with: "-")
        let quarantineURL = quarantineRoot.appendingPathComponent(
            targetFolderName,
            isDirectory: true
        )
        let plannedMoves = Self.cleanupItems(in: sourceURL).map { item in
            let destination = Self.uniqueDestination(for: item.lastPathComponent, in: quarantineURL)
            return CleanupIntent.MoveOperation(
                source: item.path,
                destination: destination.path,
                sizeBytes: Self.itemSize(at: item)
            )
        }
        return PlannedDiskCleanupTarget(
            target: target,
            quarantineURL: quarantineURL,
            plannedMoves: plannedMoves
        )
    }

    func executeCleanup(_ plan: DiskCleanupPlan) -> CleanupExecutionResult {
        var movedItems: [CleanupItem] = []
        var totalBytes: UInt64 = 0
        var errors: [String] = []

        for targetPlan in plan.targets {
            do {
                try FileManager.default.createDirectory(
                    at: targetPlan.quarantineURL,
                    withIntermediateDirectories: true
                )
            } catch {
                errors.append("Failed to create quarantine folder for \(targetPlan.target.name).")
                continue
            }

            for move in targetPlan.plannedMoves {
                let sourceURL = URL(fileURLWithPath: move.source)
                let destinationURL = URL(fileURLWithPath: move.destination)
                do {
                    try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                    movedItems.append(
                        CleanupItem(
                            id: UUID(),
                            originalPath: move.source,
                            quarantinePath: move.destination,
                            sizeBytes: move.sizeBytes
                        )
                    )
                    totalBytes += move.sizeBytes
                } catch {
                    errors.append("Failed to move \(move.source).")
                }
            }
        }

        let action = CleanupAction(
            id: UUID(),
            date: Date(),
            targets: plan.targets.map(\.target.name),
            totalBytes: totalBytes,
            items: movedItems
        )
        return CleanupExecutionResult(action: action, errors: errors)
    }

    func allowedTargets(for safeMode: Bool) -> [DiskCleanupTarget] {
        guard safeMode else { return targets }
        return targets.filter { safeAllowedPaths.contains($0.path) }
    }

    static func cleanupItems(in folder: URL) -> [URL] {
        let fileManager = FileManager.default
        return (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    static func defaultTargets() -> [DiskCleanupTarget] {
        var targets: [DiskCleanupTarget] = []
        targets.append(DiskCleanupTarget(name: "User Caches", path: "~/Library/Caches"))
        targets.append(DiskCleanupTarget(name: "System Caches", path: "/Library/Caches"))
        targets.append(DiskCleanupTarget(name: "User Logs", path: "~/Library/Logs"))
        targets.append(DiskCleanupTarget(name: "System Logs", path: "/Library/Logs"))
        targets.append(DiskCleanupTarget(name: "Temporary", path: "/tmp"))
        targets.append(DiskCleanupTarget(name: "System Temp", path: "/private/var/tmp"))
        targets.append(DiskCleanupTarget(name: "System Log Archive", path: "/private/var/log"))
        return targets
    }

    static func quarantineRoot() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = appSupport.appendingPathComponent(
            "\(ProductIdentity.stableApplicationSupportDirectoryName)/Quarantine",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func uniqueDestination(for fileName: String, in folder: URL) -> URL {
        let base = folder.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: base.path) {
            return base
        }

        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        var counter = 1
        while true {
            let candidateName = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    static func itemSize(at url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize {
            return UInt64(size)
        }
        return 0
    }
}
