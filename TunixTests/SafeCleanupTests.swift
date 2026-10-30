@testable import Tunix
import XCTest

final class SafeCleanupTests: XCTestCase {
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

    func testDeleteRemovesEligibleFileAndSeparatesObservedSpaceFromEstimate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("eligible.bin")
        try Data(repeating: 7, count: 4096).write(to: file)

        let candidate = try XCTUnwrap(candidate(in: fixture.root))
        let result = SafeCleanupEngine().delete(candidates: [candidate])

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

        let candidate = try XCTUnwrap(candidate(in: fixture.root))
        let result = SafeCleanupEngine().delete(candidates: [candidate]) { _ in
            try? Data("after".utf8).write(to: file)
        }

        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.staleCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeleteFailureIsNotReportedAsSuccessfulDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("blocked.txt")
        try Data("blocked".utf8).write(to: file)

        let candidate = try XCTUnwrap(candidate(in: fixture.root))
        let result = SafeCleanupEngine(storage: FailingCleanupStorage(failingPath: file.path))
            .delete(candidates: [candidate])

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

    func enumerateItems(at root: URL) throws -> [URL] {
        try base.enumerateItems(at: root)
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
