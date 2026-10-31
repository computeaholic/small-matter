@testable import Tunix
import XCTest

final class SafeCleanupTests: XCTestCase {
    func testAppStoreDisablesUnqualifiedUserSelectedPermanentDeletion() {
        XCTAssertFalse(CleanupDistributionContext.appStore.allowsUserSelectedPermanentDeletion)
        XCTAssertTrue(CleanupDistributionContext.direct.allowsUserSelectedPermanentDeletion)
    }

    func testDefaultProductionRootIsSmallMatterOwnedAndDoesNotInventCandidates() {
        let roots = SafeCleanupEngine.defaultRoots(fileManager: FileManager.default)

        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].scope, .appOwned)
        XCTAssertTrue(roots[0].url.path.hasSuffix("/Library/Caches/Tunix-LLC.Tunix"))
        XCTAssertEqual(
            SafeCleanupEngine().inventory(roots: roots).candidates.count,
            0,
            "An empty ordinary installation must not invent production cleanup data."
        )
    }

    func testInventoryBoundAndCancellationBlockDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("one".utf8).write(to: fixture.root.appendingPathComponent("one.bin"))
        try Data("two".utf8).write(to: fixture.root.appendingPathComponent("two.bin"))
        let root = CleanupRoot(
            id: "fixture",
            name: "Fixture",
            url: fixture.root,
            explanation: "Fixture-owned disposable data."
        )

        let limited = SafeCleanupEngine().inventory(roots: [root], maxItemsPerRoot: 1)
        XCTAssertFalse(limited.isComplete)
        XCTAssertEqual(limited.skipped.first(where: { $0.reason == .inventoryLimitReached })?.count, 1)

        let cancelled = SafeCleanupEngine().inventory(roots: [root], shouldCancel: { true })
        XCTAssertFalse(cancelled.isComplete)
        XCTAssertEqual(cancelled.skipped.first(where: { $0.reason == .scanCancelled })?.count, 1)
    }

    func testScanLeavesCandidatesUnselectedByDefault() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("review me".utf8).write(to: fixture.root.appendingPathComponent("review.txt"))
        let root = CleanupRoot(
            id: "fixture",
            name: "Fixture",
            url: fixture.root,
            explanation: "Fixture-owned disposable data."
        )
        let tool = DiskTool(
            roots: [root],
            ledgerURL: fixture.root.appendingPathComponent("ledger.json"),
            historyURL: fixture.root.appendingPathComponent("history.json"),
            deletionIntentURL: fixture.root.appendingPathComponent("deletion.json")
        )

        tool.scan()
        let deadline = Date().addingTimeInterval(5)
        while tool.isScanning, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(tool.inventory?.candidates.count, 1)
        XCTAssertTrue(tool.selectedCandidateIDs.isEmpty)
    }

    func testInventoryOnlyOffersSingleLinkRegularFilesInApprovedScope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeInventory()
        let root = CleanupRoot(
            id: "fixture",
            name: "Fixture disposable cache",
            url: fixture.root,
            explanation: "Fixture-owned disposable data."
        )
        let inventory = SafeCleanupEngine().inventory(roots: [root])

        XCTAssertEqual(inventory.candidates.map(\.displayName), ["nested-safe.txt", "safe.txt"])
        XCTAssertGreaterThanOrEqual(
            inventory.skipped.first(where: { $0.reason == .symbolicLink })?.count ?? 0,
            1
        )
        XCTAssertEqual(inventory.skipped.first(where: { $0.reason == .hardLink })?.count, 2)
        XCTAssertEqual(inventory.skipped.first(where: { $0.reason == .hidden })?.count, 1)
    }

    func testInventoryRejectsFileOnDifferentFilesystemDevice() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("mounted-file.bin")
        try Data("mounted".utf8).write(to: file)
        let root = CleanupRoot(
            id: "fixture",
            name: "Fixture",
            url: fixture.root,
            explanation: "Fixture-owned disposable data."
        )
        let storage = DifferentFilesystemCleanupStorage(mismatchedPath: file.path)

        let inventory = SafeCleanupEngine(storage: storage).inventory(roots: [root])

        XCTAssertTrue(inventory.candidates.isEmpty)
        XCTAssertEqual(
            inventory.skipped.first(where: { $0.reason == .outsideApprovedScope })?.count,
            1
        )
    }

    func testDeleteRemovesEligibleFileAndSeparatesObservedSpaceFromEstimate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("eligible.bin")
        try Data(repeating: 7, count: 4096).write(to: file)

        let root = CleanupRoot(
            id: "fixture",
            name: "Fixture",
            url: fixture.root,
            explanation: "Fixture-owned disposable data."
        )
        let candidate = try XCTUnwrap(candidate(in: fixture.root))
        let result = SafeCleanupEngine().delete(candidates: [candidate], roots: [root])

        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.staleCount, 0)
        XCTAssertEqual(result.estimatedAllocatedBytes, candidate.allocatedBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeleteLeavesFileWhenItChangesAfterInventory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("changing.txt")
        try Data("before".utf8).write(to: file)

        let root = CleanupRoot(
            id: "fixture",
            name: "Fixture",
            url: fixture.root,
            explanation: "Fixture-owned disposable data."
        )
        let candidate = try XCTUnwrap(candidate(in: fixture.root))
        let result = SafeCleanupEngine().delete(candidates: [candidate], roots: [root]) { _ in
            try? Data("after".utf8).write(to: file)
        }

        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.staleCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testPartialDeletionAccountsForConcurrentMutation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("first.bin")
        let second = fixture.root.appendingPathComponent("second.bin")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let root = CleanupRoot(
            id: "fixture",
            name: "Fixture",
            url: fixture.root,
            explanation: "Fixture-owned disposable data."
        )
        let engine = SafeCleanupEngine()
        let candidates = engine.inventory(roots: [root]).candidates

        let result = engine.delete(candidates: candidates, roots: [root]) { candidate in
            if candidate.displayName == "second.bin" {
                try? Data("changed".utf8).write(to: second)
            }
        }

        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(result.staleCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testDeleteFailureIsNotReportedAsSuccessfulDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("blocked.txt")
        try Data("blocked".utf8).write(to: file)

        let root = CleanupRoot(
            id: "fixture",
            name: "Fixture",
            url: fixture.root,
            explanation: "Fixture-owned disposable data."
        )
        let candidate = try XCTUnwrap(candidate(in: fixture.root))
        let result = SafeCleanupEngine(storage: FailingCleanupStorage(failingPath: file.path))
            .delete(candidates: [candidate], roots: [root])

        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertFalse(result.isSuccessful)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(result.diagnostics.first?.reason, "Permission or filesystem failure")
    }

    func testActionLedgerRetainsOnlyUnresolvedItemsAfterPartialRestoreAccounting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ledger = ActionLedger(ledgerURL: fixture.root.appendingPathComponent("action-ledger.json"))
        let unresolved = CleanupItem(
            id: UUID(),
            originalPath: fixture.root.appendingPathComponent("unresolved.txt").path,
            quarantinePath: fixture.root.appendingPathComponent("unresolved-quarantine.txt").path,
            sizeBytes: 6
        )
        let action = CleanupAction(
            id: UUID(),
            date: .now,
            targets: ["Fixture"],
            totalBytes: 10,
            items: [
                CleanupItem(
                    id: UUID(),
                    originalPath: fixture.root.appendingPathComponent("resolved.txt").path,
                    quarantinePath: fixture.root.appendingPathComponent("resolved-quarantine.txt").path,
                    sizeBytes: 4
                ),
                unresolved
            ]
        )
        ledger.append(action)
        ledger.replaceLast(
            CleanupAction(
                id: action.id,
                date: action.date,
                targets: action.targets,
                totalBytes: unresolved.sizeBytes,
                items: [unresolved]
            )
        )

        XCTAssertEqual(ledger.last()?.items.map(\.id), [unresolved.id])
        XCTAssertTrue(ledger.removeLast(ifMatching: action.id))
        XCTAssertNil(ledger.last())
    }
}

private extension SafeCleanupTests {
    func candidate(in root: URL) -> CleanupCandidate? {
        let rootDefinition = CleanupRoot(
            id: "fixture",
            name: "Fixture",
            url: root,
            explanation: "Fixture-owned disposable data."
        )
        return SafeCleanupEngine().inventory(roots: [rootDefinition]).candidates.first
    }
}

private struct FailingCleanupStorage: CleanupStorage {
    let base = LocalCleanupStorage()
    let failingPath: String

    func enumerateItems(
        at root: URL,
        limit: Int,
        shouldCancel: () -> Bool
    ) throws -> CleanupEnumerationResult {
        try base.enumerateItems(at: root, limit: limit, shouldCancel: shouldCancel)
    }

    func metadata(for url: URL) throws -> CleanupFileMetadata {
        try base.metadata(for: url)
    }

    func exists(at url: URL) -> Bool {
        base.exists(at: url)
    }

    func deleteItem(at url: URL) throws {
        if url.path == failingPath {
            throw CleanupStorageError.metadataUnavailable
        }
        try base.deleteItem(at: url)
    }

    func deleteItem(
        at url: URL,
        relativeTo root: URL,
        expectedFingerprint: CleanupFileFingerprint
    ) throws {
        if url.path == failingPath {
            throw CleanupStorageError.metadataUnavailable
        }
        try base.deleteItem(at: url, relativeTo: root, expectedFingerprint: expectedFingerprint)
    }

    func availableBytes(at url: URL) -> UInt64? {
        base.availableBytes(at: url)
    }
}

private struct DifferentFilesystemCleanupStorage: CleanupStorage {
    let base = LocalCleanupStorage()
    let mismatchedPath: String

    func enumerateItems(
        at root: URL,
        limit: Int,
        shouldCancel: () -> Bool
    ) throws -> CleanupEnumerationResult {
        try base.enumerateItems(at: root, limit: limit, shouldCancel: shouldCancel)
    }

    func metadata(for url: URL) throws -> CleanupFileMetadata {
        let metadata = try base.metadata(for: url)
        guard url.standardizedFileURL.path == mismatchedPath else { return metadata }
        return CleanupFileMetadata(
            identity: metadata.identity,
            path: metadata.path,
            logicalBytes: metadata.logicalBytes,
            allocatedBytes: metadata.allocatedBytes,
            modificationDate: metadata.modificationDate,
            resourceIdentifier: "different-device:\(metadata.resourceIdentifier ?? "file")",
            isDirectory: metadata.isDirectory,
            isSymbolicLink: metadata.isSymbolicLink,
            hardLinkCount: metadata.hardLinkCount,
            isReadable: metadata.isReadable,
            isWritable: metadata.isWritable
        )
    }

    func exists(at url: URL) -> Bool {
        base.exists(at: url)
    }

    func deleteItem(at url: URL) throws {
        try base.deleteItem(at: url)
    }

    func deleteItem(
        at url: URL,
        relativeTo root: URL,
        expectedFingerprint: CleanupFileFingerprint
    ) throws {
        try base.deleteItem(at: url, relativeTo: root, expectedFingerprint: expectedFingerprint)
    }

    func availableBytes(at url: URL) -> UInt64? {
        base.availableBytes(at: url)
    }
}

private final class Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("small-matter-safe-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeInventory() throws {
        try Data("safe-file".utf8).write(to: root.appendingPathComponent("safe.txt"))
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested-file".utf8).write(to: nested.appendingPathComponent("nested-safe.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))

        let hardLinkSource = root.appendingPathComponent("hard-source.txt")
        try Data("hard".utf8).write(to: hardLinkSource)
        try FileManager.default.linkItem(
            at: hardLinkSource,
            to: root.appendingPathComponent("hard-link.txt")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("symlink.txt"),
            withDestinationURL: root.appendingPathComponent("safe.txt")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
