@testable import Tunix
import XCTest

final class SafeCleanupTests: XCTestCase {
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

    func testXcodeDerivedDataRootRequiresDocumentedLocation() throws {
        let fixture = try DerivedDataFixture()
        defer { fixture.remove() }

        XCTAssertNotNil(SafeCleanupEngine.xcodeDerivedDataRoot(at: fixture.root))
        XCTAssertNil(SafeCleanupEngine.xcodeDerivedDataRoot(at: fixture.root.deletingLastPathComponent()))
    }

    func testUserSelectedDerivedDataIsUsefulOnlyWhenNoDevelopmentProcessIsActive() throws {
        let fixture = try DerivedDataFixture()
        defer { fixture.remove() }
        try Data(repeating: 1, count: 4096).write(to: fixture.root.appendingPathComponent("project-build.bin"))

        let root = try XCTUnwrap(SafeCleanupEngine.xcodeDerivedDataRoot(at: fixture.root))
        let idleEngine = SafeCleanupEngine(activeDevelopmentProcessNames: { [] })
        let idleInventory = idleEngine.inventory(roots: [root])
        XCTAssertEqual(idleInventory.candidates.map(\.displayName), ["project-build.bin"])
        XCTAssertGreaterThan(idleInventory.estimatedAllocatedBytes, 0)

        let activeInventory = SafeCleanupEngine(activeDevelopmentProcessNames: { ["Xcode"] })
            .inventory(roots: [root])
        XCTAssertTrue(activeInventory.candidates.isEmpty)
        XCTAssertEqual(
            activeInventory.skipped.first(where: { $0.reason == .activeDevelopmentProcess })?.count,
            1
        )
    }

    func testUserSelectedDerivedDataDeletionUsesIsolatedFixtureAndVerifiesOutcome() throws {
        let fixture = try DerivedDataFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("regenerable.bin")
        try Data(repeating: 7, count: 4096).write(to: file)
        let root = try XCTUnwrap(SafeCleanupEngine.xcodeDerivedDataRoot(at: fixture.root))
        let engine = SafeCleanupEngine(activeDevelopmentProcessNames: { [] })
        let candidate = try XCTUnwrap(engine.inventory(roots: [root]).candidates.first)

        let result = engine.delete(candidates: [candidate], roots: [root])

        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeletionRefusesParentSymlinkSwapAfterInventory() throws {
        let fixture = try DerivedDataFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("race.bin")
        try Data("safe".utf8).write(to: file)
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("outside-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("race.bin")
        try Data("outside".utf8).write(to: outsideFile)
        let root = try XCTUnwrap(SafeCleanupEngine.xcodeDerivedDataRoot(at: fixture.root))
        let engine = SafeCleanupEngine(activeDevelopmentProcessNames: { [] })
        let candidate = try XCTUnwrap(engine.inventory(roots: [root]).candidates.first)

        let result = engine.delete(candidates: [candidate], roots: [root]) { _ in
            try? FileManager.default.moveItem(at: fixture.root, to: fixture.renamedRoot)
            try? FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: outside)
        }

        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.staleCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: fixture.renamedRoot.appendingPathComponent("race.bin").path))
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.moveItem(at: fixture.renamedRoot, to: fixture.root)
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

private final class DerivedDataFixture {
    let root: URL
    let renamedRoot: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("small-matter-derived-data-(UUID().uuidString)", isDirectory: true)
        root = base
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        renamedRoot = base
            .appendingPathComponent("Library/Developer/Xcode/DerivedData-renamed", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: renamedRoot)
        let base = root
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
    }
}
