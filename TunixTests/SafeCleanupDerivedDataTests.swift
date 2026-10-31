@testable import Tunix
import XCTest

extension SafeCleanupTests {
    func testXcodeDerivedDataRootRequiresDocumentedLocation() throws {
        let fixture = try DerivedDataFixture()
        defer { fixture.remove() }

        XCTAssertNotNil(
            SafeCleanupEngine.xcodeDerivedDataRoot(at: fixture.root, expectedRoot: fixture.root)
        )
        XCTAssertNil(
            SafeCleanupEngine.xcodeDerivedDataRoot(
                at: fixture.root.deletingLastPathComponent(),
                expectedRoot: fixture.root
            )
        )
        XCTAssertNil(
            SafeCleanupEngine.xcodeDerivedDataRoot(
                at: fixture.lookalikeRoot,
                expectedRoot: fixture.root
            )
        )
        XCTAssertNil(
            SafeCleanupEngine.xcodeDerivedDataRoot(
                at: fixture.symlinkedRoot,
                expectedRoot: fixture.symlinkedRoot
            )
        )
    }

    func testUserSelectedDerivedDataIsUsefulOnlyWhenNoDevelopmentProcessIsActive() throws {
        let fixture = try DerivedDataFixture()
        defer { fixture.remove() }
        try Data(repeating: 1, count: 4096).write(to: fixture.root.appendingPathComponent("project-build.bin"))

        let root = try XCTUnwrap(
            SafeCleanupEngine.xcodeDerivedDataRoot(at: fixture.root, expectedRoot: fixture.root)
        )
        let idleEngine = SafeCleanupEngine(developmentProcessSnapshot: { .init(
            names: [],
            isComplete: true,
            failureReason: nil
        ) })
        let idleInventory = idleEngine.inventory(roots: [root])
        XCTAssertEqual(idleInventory.candidates.map(\.displayName), ["project-build.bin"])
        XCTAssertGreaterThan(idleInventory.estimatedAllocatedBytes, 0)

        let activeInventory = SafeCleanupEngine(developmentProcessSnapshot: {
            .init(names: ["Xcode"], isComplete: true, failureReason: nil)
        })
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
        let root = try XCTUnwrap(
            SafeCleanupEngine.xcodeDerivedDataRoot(at: fixture.root, expectedRoot: fixture.root)
        )
        let engine = SafeCleanupEngine(developmentProcessSnapshot: { .init(
            names: [],
            isComplete: true,
            failureReason: nil
        ) })
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
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("race.bin")
        try Data("outside".utf8).write(to: outsideFile)
        let root = try XCTUnwrap(
            SafeCleanupEngine.xcodeDerivedDataRoot(at: fixture.root, expectedRoot: fixture.root)
        )
        let engine = SafeCleanupEngine(developmentProcessSnapshot: { .init(
            names: [],
            isComplete: true,
            failureReason: nil
        ) })
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

    func testProcessDetectionUnavailableFailsClosed() throws {
        let fixture = try DerivedDataFixture()
        defer { fixture.remove() }
        try Data("safe".utf8).write(to: fixture.root.appendingPathComponent("safe.bin"))
        let root = try XCTUnwrap(
            SafeCleanupEngine.xcodeDerivedDataRoot(at: fixture.root, expectedRoot: fixture.root)
        )

        let inventory = SafeCleanupEngine(developmentProcessSnapshot: { .unavailable })
            .inventory(roots: [root])

        XCTAssertTrue(inventory.candidates.isEmpty)
        XCTAssertFalse(inventory.isComplete)
        XCTAssertEqual(
            inventory.skipped.first(where: { $0.reason == .processDetectionUnavailable })?.count,
            1
        )
    }

    func testRealSwiftCompilerProcessClosesDerivedDataGate() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("small-matter-process-gate-\(UUID().uuidString).swift")
        let output = source.deletingPathExtension().appendingPathExtension("out")
        let functions = (0 ..< 20000).map { "func generated\($0)() -> Int { \($0) }" }.joined(separator: "\n")
        try functions.write(to: source, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        process.arguments = [source.path, "-o", output.path]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let deadline = Date().addingTimeInterval(10)
        var observed = false
        var lastSnapshot = DevelopmentProcessSnapshot.unavailable
        while process.isRunning, Date() < deadline {
            let snapshot = LocalCleanupStorage.activeDevelopmentProcessSnapshot()
            lastSnapshot = snapshot
            if snapshot.isComplete,
               snapshot.names.contains(where: { ["swiftc", "swift-frontend"].contains($0) }) {
                observed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(
            observed,
            "The process snapshot must observe an actual command-line Swift compiler; last snapshot: \(lastSnapshot)"
        )
    }
}

final class DerivedDataFixture {
    let root: URL
    let renamedRoot: URL
    let lookalikeRoot: URL
    let symlinkedRoot: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("small-matter-derived-data-\(UUID().uuidString)", isDirectory: true)
        root = base
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        renamedRoot = base
            .appendingPathComponent("Library/Developer/Xcode/DerivedData-renamed", isDirectory: true)
        lookalikeRoot = base
            .appendingPathComponent("Other/Library/Developer/Xcode/DerivedData", isDirectory: true)
        let symlinkTarget = base.appendingPathComponent("real", isDirectory: true)
        let symlinkParent = base.appendingPathComponent("symlinked", isDirectory: true)
        symlinkedRoot = symlinkParent
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lookalikeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: symlinkTarget.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: symlinkParent, withDestinationURL: symlinkTarget)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: renamedRoot)
        try? FileManager.default.removeItem(at: lookalikeRoot)
        try? FileManager.default.removeItem(at: symlinkedRoot)
        let base = root
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
    }
}
