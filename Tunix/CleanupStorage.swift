import AppKit
import Foundation

protocol CleanupStorage {
    func enumerateItems(at root: URL) throws -> [URL]
    func metadata(for url: URL) throws -> CleanupFileMetadata
    func exists(at url: URL) -> Bool
    func deleteItem(at url: URL) throws
    func availableBytes(at url: URL) -> UInt64?
}

struct LocalCleanupStorage: CleanupStorage {
    private let fileManager: FileManager

    private static let developmentProcessNames: Set<String> = [
        "Xcode", "xcodebuild", "swift-build", "swift-package", "swiftc", "swift-frontend",
        "SourceKitService", "clang", "clang++", "ld", "ibtool", "actool", "metal",
        "codesign", "dsymutil"
    ]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func enumerateItems(at root: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CleanupStorageError.rootIsNotDirectory
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isReadableKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }

    func metadata(for url: URL) throws -> CleanupFileMetadata {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ])
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let logicalBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let allocatedBytes = UInt64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? Int(logicalBytes)
        )
        let resourceIdentifier = attributes[.systemFileNumber].map { String(describing: $0) }
        let identity = "\(url.standardizedFileURL.path)#\(resourceIdentifier ?? "path")"
        let hardLinkCount = (attributes[.referenceCount] as? NSNumber)?.uint64Value ?? 1
        let isSymbolicLink = (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
        return CleanupFileMetadata(
            identity: identity,
            path: url.standardizedFileURL.path,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            modificationDate: attributes[.modificationDate] as? Date,
            resourceIdentifier: resourceIdentifier,
            isDirectory: values.isDirectory ?? ((attributes[.type] as? FileAttributeType) == .typeDirectory),
            isSymbolicLink: isSymbolicLink,
            hardLinkCount: hardLinkCount,
            isReadable: fileManager.isReadableFile(atPath: url.path),
            isWritable: fileManager.isWritableFile(atPath: url.path)
        )
    }

    func exists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func deleteItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func availableBytes(at url: URL) -> UInt64? {
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: url.path),
              let freeBytes = attributes[.systemFreeSize] as? NSNumber
        else { return nil }
        return freeBytes.uint64Value
    }

    static func activeDevelopmentProcessNames() -> [String] {
        let activeNames = NSWorkspace.shared.runningApplications.compactMap { application -> String? in
            guard let name = application.localizedName,
                  developmentProcessNames.contains(name)
            else { return nil }
            return name
        }
        return Array(Set(activeNames)).sorted()
    }
}

enum CleanupStorageError: Error, Equatable {
    case rootIsNotDirectory
    case metadataUnavailable
}
