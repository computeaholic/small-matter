import DiskArbitration
import Foundation
import IOKit
import IOKit.storage

protocol StorageInventoryProviding: AnyObject, Sendable {
    func currentInventory(occurrence: EvidenceSourceOccurrence) -> StorageInventorySnapshot
}

/// The only identity conversion used by the native inventory and live
/// Disk Arbitration callbacks. NSWorkspace volume notifications use the same
/// volume-path/name preference through `identity(forVolumeURL:disk:)`.
enum NativeStorageIdentityNormalizer {
    static func identity(
        from disk: DADisk,
        fallbackBSDName: String? = nil,
        fallbackMediaUUID: String? = nil,
        fallbackWholeDisk: Bool? = nil
    ) -> StorageRawIdentity {
        guard let copied = DADiskCopyDescription(disk) else {
            return StorageRawIdentity(
                volumeName: nil,
                filesystemPath: nil,
                serialNumber: nil,
                hardwareUUID: nil,
                mediaUUID: fallbackMediaUUID,
                bsdName: fallbackBSDName,
                isWholeDisk: fallbackWholeDisk
            )
        }

        let dictionary = copied as NSDictionary
        let volumeName = dictionary[kDADiskDescriptionVolumeNameKey as String] as? String
        let filesystemPath = (dictionary[kDADiskDescriptionVolumePathKey as String] as? NSURL)?.path
        let mediaUUID = stringValue(dictionary[kDADiskDescriptionMediaUUIDKey as String]) ?? fallbackMediaUUID
        let hardwareUUID = stringValue(dictionary[kDADiskDescriptionDeviceGUIDKey as String])
        let bsdName = dictionary[kDADiskDescriptionMediaBSDNameKey as String] as? String ?? fallbackBSDName
        let wholeDisk = (dictionary[kDADiskDescriptionMediaWholeKey as String] as? NSNumber)?.boolValue
            ?? fallbackWholeDisk
        return StorageRawIdentity(
            volumeName: volumeName,
            filesystemPath: filesystemPath,
            serialNumber: nil,
            hardwareUUID: hardwareUUID,
            mediaUUID: mediaUUID,
            bsdName: bsdName,
            isWholeDisk: wholeDisk
        )
    }

    static func identity(forVolumeURL url: URL, disk: DADisk?) -> StorageRawIdentity {
        let diskIdentity = disk.map { identity(from: $0) }
        return StorageRawIdentity(
            volumeName: diskIdentity?.volumeName ?? url.lastPathComponent,
            filesystemPath: diskIdentity?.filesystemPath ?? url.path,
            serialNumber: diskIdentity?.serialNumber,
            hardwareUUID: diskIdentity?.hardwareUUID,
            mediaUUID: diskIdentity?.mediaUUID,
            bsdName: diskIdentity?.bsdName,
            isWholeDisk: diskIdentity?.isWholeDisk ?? false
        )
    }

    static func identity(
        fromIOKitProperties properties: NSDictionary,
        disk: DADisk?
    ) -> StorageRawIdentity {
        let bsdName = properties[kIOBSDNameKey as String] as? String
        let mediaUUID = stringValue(properties[kIOMediaUUIDKey as String])
        let wholeDisk = (properties[kIOMediaWholeKey as String] as? NSNumber)?.boolValue
        return disk.map {
            identity(
                from: $0,
                fallbackBSDName: bsdName,
                fallbackMediaUUID: mediaUUID,
                fallbackWholeDisk: wholeDisk
            )
        } ?? StorageRawIdentity(
            volumeName: nil,
            filesystemPath: nil,
            serialNumber: nil,
            hardwareUUID: nil,
            mediaUUID: mediaUUID,
            bsdName: bsdName,
            isWholeDisk: wholeDisk
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty {
            return value
        }
        if let value = value as? UUID {
            return value.uuidString
        }
        if let value = value as? NSUUID {
            return value.uuidString
        }
        return nil
    }
}

final class NativeStorageInventoryProvider: StorageInventoryProviding, @unchecked Sendable {
    private let maximumEntities: Int

    init(maximumEntities: Int = 512) {
        self.maximumEntities = max(1, maximumEntities)
    }

    // Why: ordered canonical flow.
    // Why: ordered canonical flow.
    // swiftlint:disable:next function_body_length
    func currentInventory(occurrence: EvidenceSourceOccurrence) -> StorageInventorySnapshot {
        let started = DispatchTime.now().uptimeNanoseconds
        let onMainThread = Thread.isMainThread
        var events: [StorageRawEvent] = []
        var seen: Set<String> = []
        var failure: StorageInventoryFailure?
        var diskCount = 0
        var volumeCount = 0

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            let duration = DispatchTime.now().uptimeNanoseconds - started
            return StorageInventorySnapshot.unavailable(
                .diskArbitrationUnavailable,
                metrics: StorageInventoryMetrics(
                    snapshotDurationNanoseconds: duration,
                    diskCount: 0,
                    mountedVolumeCount: 0,
                    performedOnMainThread: onMainThread
                )
            )
        }

        let mediaResult = enumerateMedia(
            session: session,
            occurrence: occurrence,
            events: &events,
            seen: &seen,
            count: &diskCount
        )
        if !mediaResult.succeeded {
            failure = .ioRegistryUnavailable
        } else if mediaResult.truncated {
            failure = .partialInventory
        }

        if let mountedURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [],
            options: []
        ) {
            if mountedURLs.count > maximumEntities {
                failure = failure ?? .partialInventory
            }
            for url in mountedURLs.prefix(maximumEntities) {
                let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL)
                let identity = NativeStorageIdentityNormalizer.identity(forVolumeURL: url, disk: disk)
                guard identity.stateIdentifier(for: .volume) != nil else {
                    failure = failure ?? .partialInventory
                    continue
                }
                let raw = StorageRawEvent(
                    kind: .volumeMounted,
                    identity: identity,
                    occurrence: occurrence,
                    callbackToken: "native-volume-baseline",
                    semanticRole: .baseline
                )
                let key = "volume:\(identity.stateIdentifier(for: .volume) ?? "")"
                if seen.insert(key).inserted {
                    events.append(raw)
                    volumeCount += 1
                }
            }
        } else {
            failure = failure ?? .mountedVolumeUnavailable
        }

        let duration = DispatchTime.now().uptimeNanoseconds - started
        let metrics = StorageInventoryMetrics(
            snapshotDurationNanoseconds: duration,
            diskCount: diskCount,
            mountedVolumeCount: volumeCount,
            performedOnMainThread: onMainThread
        )
        if let failure {
            return StorageInventorySnapshot.unavailable(failure, events: events, metrics: metrics)
        }
        return .available(events, metrics: metrics)
    }

    private func enumerateMedia(
        session: DASession,
        occurrence: EvidenceSourceOccurrence,
        events: inout [StorageRawEvent],
        seen: inout Set<String>,
        count: inout Int
    ) -> (succeeded: Bool, truncated: Bool) {
        guard let matching = IOServiceMatching(kIOMediaClass) else { return (false, false) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (false, false)
        }
        defer { IOObjectRelease(iterator) }

        var inspected = 0
        while inspected < maximumEntities {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            inspected += 1
            defer { IOObjectRelease(service) }

            var unmanagedProperties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service,
                &unmanagedProperties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS,
                let unmanagedProperties
            else { continue }
            let properties = unmanagedProperties.takeRetainedValue() as NSDictionary
            guard let bsdName = properties[kIOBSDNameKey as String] as? String, !bsdName.isEmpty else { continue }

            let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName)
            let identity = NativeStorageIdentityNormalizer.identity(fromIOKitProperties: properties, disk: disk)
            guard let identifier = identity.stateIdentifier(for: .disk) else { continue }
            let key = "disk:\(identifier)"
            guard seen.insert(key).inserted else { continue }
            events.append(StorageRawEvent(
                kind: .diskAppeared,
                identity: identity,
                occurrence: occurrence,
                callbackToken: "native-disk-baseline",
                semanticRole: .baseline
            ))
            count += 1
        }
        let extra = inspected == maximumEntities ? IOIteratorNext(iterator) : 0
        if extra != 0 {
            IOObjectRelease(extra)
        }
        let truncated = extra != 0
        return (true, truncated)
    }
}

struct StorageInitializationBuffer: Sendable {
    struct Entry: Sendable {
        let order: UInt64
        let raw: StorageRawEvent
    }

    private let maximumEntries: Int
    private(set) var entries: [Entry] = []
    private(set) var droppedCount = 0
    private var nextOrder: UInt64 = 0

    init(maximumEntries: Int = 256) {
        self.maximumEntries = max(1, maximumEntries)
    }

    mutating func append(_ raw: StorageRawEvent) {
        nextOrder += 1
        guard entries.count < maximumEntries else {
            droppedCount += 1
            return
        }
        entries.append(Entry(order: nextOrder, raw: raw))
    }

    mutating func drain() -> [Entry] {
        let drained = entries
        entries.removeAll(keepingCapacity: true)
        return drained
    }

    var highWaterMark: Int {
        entries.count
    }
}
