import Foundation

extension SafeCleanupEngine {
    static func standardXcodeDerivedDataURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
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

    static func xcodeDerivedDataRoot(
        at url: URL,
        fileManager: FileManager = .default,
        expectedRoot: URL? = nil
    ) -> CleanupRoot? {
        let expectedURL = (expectedRoot ?? standardXcodeDerivedDataURL(fileManager: fileManager)).standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard standardizedURL.path == expectedURL.path,
              standardizedURL.resolvingSymlinksInPath().standardizedFileURL.path == standardizedURL.path,
              expectedURL.resolvingSymlinksInPath().standardizedFileURL.path == expectedURL.path,
              fileManager.fileExists(atPath: standardizedURL.path),
              fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              sameFileSystem(
                  as: standardizedURL,
                  and: fileManager.homeDirectoryForCurrentUser,
                  fileManager: fileManager
              )
        else { return nil }

        return CleanupRoot(
            id: "user-selected-xcode-derived-data",
            name: "Xcode Derived Data",
            url: standardizedURL,
            explanation:
            "Xcode Derived Data is regenerable. Only regular files are eligible, and active Xcode/build " +
                "processes block cleanup.",
            scope: .xcodeDerivedData
        )
    }

    private static func sameFileSystem(
        as first: URL,
        and second: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let firstAttributes = try? fileManager.attributesOfFileSystem(forPath: first.path),
              let firstNumber = firstAttributes[.systemNumber] as? NSNumber,
              let secondAttributes = try? fileManager.attributesOfFileSystem(forPath: second.path),
              let secondNumber = secondAttributes[.systemNumber] as? NSNumber
        else { return false }
        return firstNumber.uint64Value == secondNumber.uint64Value
    }
}
