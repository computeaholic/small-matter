// swiftlint:disable file_length line_length trailing_comma
import AppKit
import DiskArbitration
import Foundation

private enum StorageInitializationPhase: String {
    case stopped
    case initializing
    case buffering
    case snapshot
    case reconciliation
    case live
}

// swiftlint:disable:next type_body_length
final class StorageEvidenceAdapter: Horizon2EvidenceAdapter, @unchecked Sendable {
    let sourceID: Horizon2SourceID = .storage

    private let clock: any EvidenceClock
    private let emit: @Sendable (EvidenceAdapterEmission) -> Void
    private let inventoryProvider: any StorageInventoryProviding
    private let fixtureBaselineSnapshotProvider: (@Sendable (EvidenceSourceOccurrence) -> StorageInventorySnapshot)?
    private let queue = DispatchQueue(label: "com.tunix.horizon2.storage", qos: .utility)
    private let snapshotQueue = DispatchQueue(label: "com.tunix.horizon2.storage.snapshot", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var session: DASession?
    private var notificationTokens: [NSObjectProtocol] = []
    private var duplicateGate = StorageDuplicateGate()
    private var stateMachine = StorageStateMachine()
    private var baselineEstablished = false
    private var initializationPhase: StorageInitializationPhase = .stopped
    private var initializationBuffer = StorageInitializationBuffer()
    private var snapshotStartOccurrence: EvidenceSourceOccurrence?
    private var snapshotEndOccurrence: EvidenceSourceOccurrence?
    private var bufferHighWaterMark = 0

    init(
        clock: any EvidenceClock = SystemEvidenceClock(),
        baselineSnapshotProvider: (@Sendable (EvidenceSourceOccurrence) -> StorageInventorySnapshot)? = nil,
        inventoryProvider: any StorageInventoryProviding = NativeStorageInventoryProvider(),
        emit: @escaping @Sendable (EvidenceAdapterEmission) -> Void
    ) {
        self.clock = clock
        fixtureBaselineSnapshotProvider = baselineSnapshotProvider
        self.inventoryProvider = inventoryProvider
        self.emit = emit
    }

    // swiftlint:disable:next function_body_length
    func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        duplicateGate = StorageDuplicateGate()
        stateMachine = StorageStateMachine()
        baselineEstablished = false
        initializationPhase = .initializing
        initializationBuffer = StorageInitializationBuffer()
        snapshotStartOccurrence = nil
        snapshotEndOccurrence = nil
        bufferHighWaterMark = 0
        let createdSession = DASessionCreate(kCFAllocatorDefault)
        session = createdSession
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let createdSession {
            DASessionSetDispatchQueue(createdSession, queue)
            DARegisterDiskAppearedCallback(createdSession, nil, Self.diskAppeared, context)
            DARegisterDiskDisappearedCallback(createdSession, nil, Self.diskDisappeared, context)
        }
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens = [
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] notification in
                self?.handleWorkspaceNotification(notification, kind: .volumeMounted)
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] notification in
                self?.handleWorkspaceNotification(notification, kind: .volumeUnmounted)
            },
        ]
        lock.unlock()

        if createdSession == nil {
            emit(.health(health(
                event: .startupFailure,
                reason: .permissionOrAPIUnavailable,
                detail: "DASessionCreate failed; native inventory and mounted-volume evidence remain bounded and uncertain"
            )))
        }
        emit(.health(health(
            event: .started,
            reason: .notObserved,
            detail: "Storage callbacks registered and bounded native initialization buffering started"
        )))

        if fixtureBaselineSnapshotProvider != nil {
            captureAndReconcileSnapshot()
        } else {
            snapshotQueue.async { [weak self] in
                self?.captureAndReconcileSnapshot()
            }
        }
    }

    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        initializationPhase = .stopped
        let oldSession = session
        session = nil
        let tokens = notificationTokens
        notificationTokens.removeAll()
        lock.unlock()

        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let oldSession {
            DASessionSetDispatchQueue(oldSession, nil)
            DAUnregisterCallback(oldSession, unsafeBitCast(Self.diskAppeared, to: UnsafeMutableRawPointer.self), Unmanaged.passUnretained(self).toOpaque())
            DAUnregisterCallback(oldSession, unsafeBitCast(Self.diskDisappeared, to: UnsafeMutableRawPointer.self), Unmanaged.passUnretained(self).toOpaque())
        }
        emit(.health(health(event: .stopped, reason: .notObserved, detail: "Storage observers removed")))
    }

    func reconcileAfterWake() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        duplicateGate = StorageDuplicateGate()
        stateMachine = StorageStateMachine()
        baselineEstablished = false
        initializationPhase = .buffering
        initializationBuffer = StorageInitializationBuffer()
        snapshotStartOccurrence = nil
        snapshotEndOccurrence = nil
        lock.unlock()

        emit(.health(health(
            event: .reconciliationRequired,
            reason: .incompleteCapture,
            detail: "Storage baseline is being recaptured through native inventory after wake"
        )))
        if fixtureBaselineSnapshotProvider != nil {
            captureAndReconcileSnapshot()
        } else {
            snapshotQueue.async { [weak self] in
                self?.captureAndReconcileSnapshot()
            }
        }
    }

    private func captureAndReconcileSnapshot() {
        let start = occurrence()
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        initializationPhase = .snapshot
        snapshotStartOccurrence = start
        lock.unlock()

        let snapshot = fixtureBaselineSnapshotProvider?(start) ?? inventoryProvider.currentInventory(occurrence: start)
        let end = occurrence()

        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        snapshotEndOccurrence = end
        stateMachine = StorageStateMachine(baseline: snapshot.events)
        baselineEstablished = snapshot.failure == nil
        initializationPhase = .reconciliation
        lock.unlock()

        snapshot.events.forEach { emitRaw($0.assigningSemanticRole(.baseline)) }
        reconcileBufferedCallbacks(snapshot: snapshot)

        let metricDetail = snapshot.metrics.snapshotDurationNanoseconds.map { duration in
            let milliseconds = Double(duration) / 1_000_000.0
            return String(format: "snapshot %.2f ms", milliseconds)
        } ?? "snapshot duration unavailable"
        lock.lock()
        let capturedBufferHighWaterMark = bufferHighWaterMark
        lock.unlock()
        let inventoryDetail = "\(snapshot.metrics.diskCount) disks, \(snapshot.metrics.mountedVolumeCount) mounted volumes, buffer high-water \(capturedBufferHighWaterMark), \(metricDetail)"
        if let failure = snapshot.failure {
            emit(.health(health(
                event: .sourceUnavailable,
                reason: .sourceUnavailable,
                detail: "Native storage inventory unavailable or partial: \(failure.detail); callbacks retained as uncertain; \(inventoryDetail)"
            )))
        } else {
            emit(.health(health(
                event: .reconciliationCompleted,
                reason: .notObserved,
                detail: "Current storage baseline established from native inventory; \(snapshot.events.count) facts retained; \(inventoryDetail)"
            )))
        }
        lock.lock()
        if running {
            initializationPhase = .live
        }
        lock.unlock()
    }

    private func reconcileBufferedCallbacks(snapshot: StorageInventorySnapshot) {
        while true {
            lock.lock()
            let entries = initializationBuffer.drain()
            let dropped = initializationBuffer.droppedCount
            let start = snapshotStartOccurrence
            let end = snapshotEndOccurrence
            if !entries.isEmpty {
                bufferHighWaterMark = max(bufferHighWaterMark, entries.count)
            }
            lock.unlock()

            for entry in entries.sorted(by: { $0.order < $1.order }) {
                lock.lock()
                let role: StorageRawSemanticRole
                if snapshot.failure != nil {
                    role = .uncertain
                } else if isAmbiguousSnapshotInterval(entry.raw.occurrence, start: start, end: end) {
                    role = .uncertain
                } else {
                    role = stateMachine.classify(entry.raw)
                }
                lock.unlock()
                emitRaw(entry.raw.assigningSemanticRole(role))
            }

            lock.lock()
            let stillBuffered = !initializationBuffer.entries.isEmpty
            if !stillBuffered {
                initializationPhase = .reconciliation
            }
            lock.unlock()
            if !stillBuffered {
                if dropped > 0 {
                    emit(.health(health(
                        event: .reconciliationFailure,
                        reason: .incompleteCapture,
                        suppressedCount: dropped,
                        detail: "Native storage initialization buffer reached its hard bound; dropped callbacks remain explicitly incomplete"
                    )))
                }
                return
            }
        }
    }

    private func isAmbiguousSnapshotInterval(
        _ occurrence: EvidenceSourceOccurrence,
        start: EvidenceSourceOccurrence?,
        end: EvidenceSourceOccurrence?
    ) -> Bool {
        guard let callback = occurrence.continuousNanoseconds,
              let start = start?.continuousNanoseconds,
              let end = end?.continuousNanoseconds
        else { return false }
        return callback >= start && callback <= end
    }

    private func handleWorkspaceNotification(_ notification: Notification, kind: StorageRawEventKind) {
        guard isRunning else { return }
        let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
        let currentSession: DASession?
        lock.lock()
        currentSession = session
        lock.unlock()
        let disk = volumeURL.flatMap { url in
            currentSession.flatMap { DADiskCreateFromVolumePath(kCFAllocatorDefault, $0, url as CFURL) }
        }
        let identity = volumeURL.map { NativeStorageIdentityNormalizer.identity(forVolumeURL: $0, disk: disk) }
            ?? StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: nil, bsdName: nil, isWholeDisk: false)
        receive(StorageRawEvent(
            kind: kind,
            identity: identity,
            occurrence: occurrence(),
            callbackToken: nil
        ))
    }

    private func emitDisk(_ disk: DADisk, kind: StorageRawEventKind) {
        guard isRunning else { return }
        receive(StorageRawEvent(
            kind: kind,
            identity: NativeStorageIdentityNormalizer.identity(from: disk),
            occurrence: occurrence(),
            callbackToken: nil
        ))
    }

    private func receive(_ raw: StorageRawEvent) {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        guard initializationPhase == .live else {
            initializationBuffer.append(raw)
            bufferHighWaterMark = max(bufferHighWaterMark, initializationBuffer.entries.count)
            lock.unlock()
            return
        }
        let suppressed = duplicateGate.shouldSuppress(raw)
        let role = baselineEstablished ? stateMachine.classify(raw) : StorageRawSemanticRole.uncertain
        lock.unlock()

        if suppressed {
            emit(.health(health(event: .duplicateSuppressed, reason: .notObserved, suppressedCount: 1, detail: "Exact higher-level storage callback delivery")))
        } else {
            emitRaw(raw.assigningSemanticRole(role))
        }
    }

    private func emitRaw(_ raw: StorageRawEvent) {
        guard isRunning else { return }
        emit(.raw(.storage(raw)))
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func occurrence() -> EvidenceSourceOccurrence {
        let reading = clock.reading()
        return EvidenceSourceOccurrence(
            wallTime: reading.wallTime,
            continuousNanoseconds: reading.continuousNanoseconds,
            quality: reading.continuousNanoseconds == nil ? .estimated : .exact
        )
    }

    private func health(
        event: EvidenceSourceHealthEvent,
        reason: EvidenceUnknownReason,
        suppressedCount: Int = 0,
        detail: String?
    ) -> EvidenceSourceHealthUpdate {
        EvidenceSourceHealthUpdate(sourceID: .storage, event: event, reason: reason, suppressedCount: suppressedCount, observedAt: clock.reading().wallTime, detail: detail)
    }

    var isReconciledForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initializationPhase == .live
    }

    var isStartupBaselineEstablishedForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return baselineEstablished
    }

    var bufferHighWaterMarkForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferHighWaterMark
    }

    func completeStartupBaselineForTesting() {}

    func receiveForTesting(_ raw: StorageRawEvent) {
        receive(raw)
    }

    // swiftlint:disable:next function_body_length
    static func parseInventoryFixture(data: Data, occurrence: EvidenceSourceOccurrence) -> StorageInventorySnapshot {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return .unavailable(.malformedPropertyList)
        }

        var events: [StorageRawEvent] = []
        var seen: Set<String> = []

        func visit(_ value: Any) {
            // swiftlint:disable opening_brace
            if let dictionary = value as? [String: Any],
               let bsdName = dictionary["DeviceIdentifier"] as? String,
               !bsdName.isEmpty
            {
                let volumeName = dictionary["VolumeName"] as? String
                let filesystemPath = dictionary["MountPoint"] as? String
                let mediaUUID = dictionary["VolumeUUID"] as? String ?? dictionary["DiskUUID"] as? String
                let identity = StorageRawIdentity(
                    volumeName: volumeName,
                    filesystemPath: filesystemPath,
                    serialNumber: nil,
                    hardwareUUID: nil,
                    mediaUUID: mediaUUID,
                    bsdName: bsdName,
                    isWholeDisk: dictionary["Partitions"] != nil ? true : false
                )
                let kinds: [StorageRawEventKind] = volumeName != nil || filesystemPath != nil
                    ? [.diskAppeared, .volumeMounted]
                    : [.diskAppeared]
                for kind in kinds {
                    let entityClass: StorageEntityClass = kind == .volumeMounted ? .volume : .disk
                    let key = "\(entityClass.rawValue):\(identity.stateIdentifier(for: entityClass) ?? bsdName)"
                    if seen.insert(key).inserted {
                        events.append(StorageRawEvent(
                            kind: kind,
                            identity: identity,
                            occurrence: occurrence,
                            callbackToken: "baseline-snapshot",
                            semanticRole: .baseline
                        ))
                    }
                }
            }
            // swiftlint:enable opening_brace
            if let dictionary = value as? [String: Any] {
                dictionary.values.forEach(visit)
            } else if let array = value as? [Any] {
                array.forEach(visit)
            }
        }

        visit(plist)
        return .available(events)
    }

    private static let diskAppeared: DADiskAppearedCallback = { disk, context in
        guard let context else { return }
        Unmanaged<StorageEvidenceAdapter>.fromOpaque(context).takeUnretainedValue().emitDisk(disk, kind: .diskAppeared)
    }

    private static let diskDisappeared: DADiskDisappearedCallback = { disk, context in
        guard let context else { return }
        Unmanaged<StorageEvidenceAdapter>.fromOpaque(context).takeUnretainedValue().emitDisk(disk, kind: .diskDisappeared)
    }

    deinit {
        stop()
    }
}

// swiftlint:enable line_length trailing_comma
