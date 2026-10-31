import Foundation

extension SafeCleanupEngine {
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
        fileManager: FileManager = .default
    ) -> CleanupRoot? {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedURL.path),
              fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              standardizedURL.resolvingSymlinksInPath().standardizedFileURL.path == standardizedURL.path
        else { return nil }

        let requiredSuffix = ["Library", "Developer", "Xcode", "DerivedData"]
        guard standardizedURL.pathComponents.suffix(requiredSuffix.count).elementsEqual(requiredSuffix)
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
}
