import Darwin
import Foundation

struct DevelopmentProcessSnapshot: Equatable {
    let names: [String]
    let isComplete: Bool
    let failureReason: String?

    static let unavailable = DevelopmentProcessSnapshot(
        names: [],
        isComplete: false,
        failureReason: "macOS did not provide a complete process snapshot"
    )
}

struct CleanupEnumerationResult {
    let items: [URL]
    let reachedLimit: Bool
    let wasCancelled: Bool
}

protocol CleanupStorage {
    func enumerateItems(
        at root: URL,
        limit: Int,
        shouldCancel: () -> Bool
    ) throws -> CleanupEnumerationResult
    func metadata(for url: URL) throws -> CleanupFileMetadata
    func exists(at url: URL) -> Bool
    func deleteItem(at url: URL) throws
    func deleteItem(
        at url: URL,
        relativeTo root: URL,
        expectedFingerprint: CleanupFileFingerprint
    ) throws
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

    func enumerateItems(
        at root: URL,
        limit: Int,
        shouldCancel: () -> Bool
    ) throws -> CleanupEnumerationResult {
        guard fileManager.fileExists(atPath: root.path) else {
            return CleanupEnumerationResult(items: [], reachedLimit: false, wasCancelled: false)
        }
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
        ) else {
            return CleanupEnumerationResult(items: [], reachedLimit: false, wasCancelled: false)
        }

        var items: [URL] = []
        items.reserveCapacity(min(limit, 1024))
        while let item = enumerator.nextObject() as? URL {
            if shouldCancel() {
                return CleanupEnumerationResult(items: items, reachedLimit: false, wasCancelled: true)
            }
            if items.count >= limit {
                return CleanupEnumerationResult(items: items, reachedLimit: true, wasCancelled: false)
            }
            items.append(item)
        }
        return CleanupEnumerationResult(items: items, reachedLimit: false, wasCancelled: false)
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
        let resourceIdentifier: String?
        if let systemNumber = attributes[.systemNumber],
           let fileNumber = attributes[.systemFileNumber] {
            resourceIdentifier = "\(systemNumber):\(fileNumber)"
        } else {
            resourceIdentifier = nil
        }
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

    func deleteItem(
        at url: URL,
        relativeTo root: URL,
        expectedFingerprint: CleanupFileFingerprint
    ) throws {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath + "/") else {
            throw CleanupStorageError.metadataUnavailable
        }
        let relativeComponents = itemPath
            .dropFirst(rootPath.count + 1)
            .split(separator: "/")
            .map(String.init)
        guard let leaf = relativeComponents.last,
              !relativeComponents.contains("."),
              !relativeComponents.contains("..")
        else {
            throw CleanupStorageError.metadataUnavailable
        }

        let rootDescriptor = rootPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootDescriptor >= 0 else { throw CleanupStorageError.metadataUnavailable }
        defer { close(rootDescriptor) }

        var descriptors: [Int32] = []
        defer { descriptors.forEach { close($0) } }
        var parentDescriptor = rootDescriptor
        for component in relativeComponents.dropLast() {
            let descriptor = component.withCString {
                openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { throw CleanupStorageError.metadataUnavailable }
            descriptors.append(descriptor)
            parentDescriptor = descriptor
        }

        var fileInfo = stat()
        let statResult = leaf.withCString {
            fstatat(parentDescriptor, $0, &fileInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0,
              fileInfo.st_mode & S_IFMT == S_IFREG,
              expectedFingerprint.resourceIdentifier == "\(fileInfo.st_dev):\(fileInfo.st_ino)",
              UInt64(fileInfo.st_size) == expectedFingerprint.logicalBytes,
              modificationDateMatches(fileInfo, expected: expectedFingerprint.modificationDate),
              leaf.withCString({ unlinkat(parentDescriptor, $0, 0) }) == 0
        else {
            throw CleanupStorageError.metadataUnavailable
        }
    }

    private func modificationDateMatches(_ fileInfo: stat, expected: Date?) -> Bool {
        guard let expected else { return true }
        let actual = Date(
            timeIntervalSince1970: Double(fileInfo.st_mtimespec.tv_sec) +
                Double(fileInfo.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return abs(actual.timeIntervalSince1970 - expected.timeIntervalSince1970) < 0.000001
    }

    func availableBytes(at url: URL) -> UInt64? {
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: url.path),
              let freeBytes = attributes[.systemFreeSize] as? NSNumber
        else { return nil }
        return freeBytes.uint64Value
    }

    static func activeDevelopmentProcessSnapshot() -> DevelopmentProcessSnapshot {
        for _ in 0 ..< 3 {
            var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var requestedBytes = 0
            guard sysctl(&mib, u_int(mib.count), nil, &requestedBytes, nil, 0) == 0,
                  requestedBytes > 0
            else { return .unavailable }

            let capacity = requestedBytes / MemoryLayout<kinfo_proc>.stride + 32
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            let returned = processes.withUnsafeMutableBytes { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &requestedBytes, nil, 0)
            }
            guard returned == 0 else { continue }
            let processCount = requestedBytes / MemoryLayout<kinfo_proc>.stride
            guard processCount <= processes.count else { continue }

            var names: Set<String> = []
            for process in processes.prefix(processCount) {
                let name = withUnsafeBytes(of: process.kp_proc.p_comm) { buffer in
                    String(
                        bytes: buffer.prefix { $0 != 0 },
                        encoding: .utf8
                    )
                }
                if let name, developmentProcessNames.contains(name) {
                    names.insert(name)
                }
            }
            return DevelopmentProcessSnapshot(
                names: names.sorted(),
                isComplete: true,
                failureReason: nil
            )
        }
        return .unavailable
    }
}

enum CleanupStorageError: Error, Equatable {
    case rootIsNotDirectory
    case metadataUnavailable
}
