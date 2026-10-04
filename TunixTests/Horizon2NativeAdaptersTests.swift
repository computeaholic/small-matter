// swiftlint:disable line_length trailing_comma identifier_name optional_data_string_conversion
// swiftlint:disable file_length
@testable import Tunix
import XCTest

final class Horizon2NativeAdaptersTests: XCTestCase { // swiftlint:disable:this type_body_length
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testStorageNormalizationKeepsDiskAndVolumeSemanticsDistinctAndRedactsIdentity() throws {
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 10, quality: .exact)
        let identity = StorageRawIdentity(
            volumeName: "Private Volume",
            filesystemPath: "/Volumes/Private Volume",
            serialNumber: "serial-secret",
            hardwareUUID: "hardware-secret",
            mediaUUID: "media-secret",
            bsdName: "disk9s1",
            isWholeDisk: false
        )
        let disk = StorageEventNormalizer.normalize(
            StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "a"),
            identityScope: "test-scope"
        )
        let volume = StorageEventNormalizer.normalize(
            StorageRawEvent(kind: .volumeMounted, identity: identity, occurrence: occurrence, callbackToken: "b"),
            identityScope: "test-scope"
        )

        XCTAssertEqual(disk.subject.type, .storageDisk)
        XCTAssertEqual(volume.subject.type, .mountedVolume)
        XCTAssertEqual(disk.eventKind, .storageDiskLifecycle)
        XCTAssertEqual(volume.eventKind, .storageMountLifecycle)
        XCTAssertEqual(disk.subject.quality, .qualified)
        XCTAssertNotNil(disk.subject.identityDigest)
        let encoded = try ObservationFixtureFactory.observation(from: disk).deterministicData()
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("Private Volume"))
        XCTAssertFalse(text.contains("/Volumes/Private Volume"))
        XCTAssertFalse(text.contains("serial-secret"))
        XCTAssertFalse(text.contains("hardware-secret"))
        XCTAssertFalse(text.contains("media-secret"))
        XCTAssertFalse(text.contains("disk9s1"))
    }

    func testStorageDuplicateGateSuppressesExactDeliveryButPreservesBurst() {
        let identity = StorageRawIdentity(volumeName: "Disk", filesystemPath: "/Volumes/Disk", serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: "disk2", isWholeDisk: true)
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 1, quality: .exact)
        var gate = StorageDuplicateGate()
        let first = StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "callback-1")
        let exactDuplicate = first
        let legitimateBurst = StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "callback-2")
        let mount = StorageRawEvent(kind: .volumeMounted, identity: identity, occurrence: occurrence, callbackToken: "callback-1")

        XCTAssertFalse(gate.shouldSuppress(first))
        XCTAssertTrue(gate.shouldSuppress(exactDuplicate))
        XCTAssertFalse(gate.shouldSuppress(legitimateBurst))
        XCTAssertFalse(gate.shouldSuppress(mount))
    }

    func testStorageStateMachineUsesSnapshotIdentityForLateBaselineCallbacks() {
        let identity = StorageRawIdentity(
            volumeName: "Backup",
            filesystemPath: "/Volumes/Backup",
            serialNumber: nil,
            hardwareUUID: nil,
            mediaUUID: "backup-media",
            bsdName: "disk4s1",
            isWholeDisk: false
        )
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 1, quality: .exact)
        let baseline = StorageRawEvent(kind: .volumeMounted, identity: identity, occurrence: occurrence, callbackToken: "snapshot", semanticRole: .baseline)
        var machine = StorageStateMachine(baseline: [baseline])

        let lateCallback = StorageRawEvent(kind: .volumeMounted, identity: identity, occurrence: occurrence, callbackToken: nil)

        XCTAssertEqual(machine.classify(lateCallback), .baseline)
        XCTAssertEqual(machine.classify(lateCallback), .baseline)
    }

    func testMountedBaselineSeedsBothDiskAndVolumeNamespaces() throws {
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 1, quality: .exact)
        let plist: [String: Any] = [
            "AllDisksAndPartitions": [[
                "DeviceIdentifier": "disk5s1",
                "DiskUUID": "disk-media",
                "VolumeUUID": "mounted-volume",
                "VolumeName": "Backup",
                "MountPoint": "/Volumes/Backup",
            ]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let events = StorageEvidenceAdapter.parseInventoryFixture(data: data, occurrence: occurrence).events

        XCTAssertEqual(events.map(\.kind), [.diskAppeared, .volumeMounted])
        XCTAssertEqual(events.filter { $0.entityClass == .disk }.count, 1)
        XCTAssertEqual(events.filter { $0.entityClass == .volume }.count, 1)
        XCTAssertEqual(events[0].identity.stateIdentifier(for: .disk), "media:mounted-volume")
        XCTAssertEqual(events[1].identity.stateIdentifier(for: .volume), "path:/Volumes/Backup")
    }

    func testStartupCallbacksForMountedBaselineAreConfirmationsAcrossBothNamespaces() throws {
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 1, quality: .exact)
        let plist: [String: Any] = [
            "AllDisksAndPartitions": [[
                "DeviceIdentifier": "disk5s1",
                "DiskUUID": "disk-media",
                "VolumeUUID": "mounted-volume",
                "VolumeName": "Backup",
                "MountPoint": "/Volumes/Backup",
            ]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let snapshot = StorageEvidenceAdapter.parseInventoryFixture(data: data, occurrence: occurrence)
        let emissions = EmissionBox()
        let adapter = StorageEvidenceAdapter(
            clock: FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 1, processUptimeNanoseconds: 1),
            baselineSnapshotProvider: { _ in snapshot },
            emit: { emissions.append($0) }
        )
        adapter.start()
        adapter.receiveForTesting(StorageRawEvent(
            kind: .diskAppeared,
            identity: StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: "mounted-volume", bsdName: "disk5s1", isWholeDisk: false),
            occurrence: occurrence,
            callbackToken: "disk-startup"
        ))
        adapter.receiveForTesting(StorageRawEvent(
            kind: .volumeMounted,
            identity: StorageRawIdentity(volumeName: "Backup", filesystemPath: "/Volumes/Backup", serialNumber: nil, hardwareUUID: nil, mediaUUID: nil, bsdName: nil, isWholeDisk: false),
            occurrence: occurrence,
            callbackToken: "volume-startup"
        ))
        adapter.stop()

        let startupCallbacks = emissions.emissions.compactMap { emission -> StorageRawEvent? in
            guard case let .raw(.storage(raw)) = emission, raw.callbackToken != "baseline-snapshot" else { return nil }
            return raw
        }
        XCTAssertEqual(startupCallbacks.map(\.semanticRole), [.baseline, .baseline])
        XCTAssertFalse(startupCallbacks.contains { $0.semanticRole == .transition })
    }

    func testDiskAndVolumeIdentityNormalizationMatchesNativeCallbackFields() {
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 1, quality: .exact)
        let diskutilIdentity = StorageRawIdentity(volumeName: "Backup", filesystemPath: "/Volumes/Backup", serialNumber: nil, hardwareUUID: nil, mediaUUID: "mounted-volume", bsdName: "disk5s1", isWholeDisk: false)
        let diskArbitrationIdentity = StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: "mounted-volume", bsdName: "disk5s1", isWholeDisk: false)
        let workspaceIdentity = StorageRawIdentity(volumeName: "Backup", filesystemPath: "/Volumes/Backup", serialNumber: nil, hardwareUUID: nil, mediaUUID: nil, bsdName: nil, isWholeDisk: false)

        XCTAssertEqual(diskutilIdentity.stateIdentifier(for: .disk), diskArbitrationIdentity.stateIdentifier(for: .disk))
        XCTAssertEqual(diskutilIdentity.stateIdentifier(for: .volume), workspaceIdentity.stateIdentifier(for: .volume))

        var machine = StorageStateMachine(baseline: [
            StorageRawEvent(kind: .diskAppeared, identity: diskutilIdentity, occurrence: occurrence, callbackToken: "diskutil", semanticRole: .baseline),
            StorageRawEvent(kind: .volumeMounted, identity: diskutilIdentity, occurrence: occurrence, callbackToken: "diskutil", semanticRole: .baseline),
        ])
        XCTAssertEqual(machine.classify(StorageRawEvent(kind: .diskAppeared, identity: diskArbitrationIdentity, occurrence: occurrence, callbackToken: "da")), .baseline)
        XCTAssertEqual(machine.classify(StorageRawEvent(kind: .volumeMounted, identity: workspaceIdentity, occurrence: occurrence, callbackToken: "workspace")), .baseline)
    }

    func testRealPostBaselineStorageTransitionsRemainTransitions() {
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 1, quality: .exact)
        let identity = StorageRawIdentity(volumeName: "Backup", filesystemPath: "/Volumes/Backup", serialNumber: nil, hardwareUUID: nil, mediaUUID: "mounted-volume", bsdName: "disk5s1", isWholeDisk: false)
        var machine = StorageStateMachine(baseline: [
            StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "baseline", semanticRole: .baseline),
            StorageRawEvent(kind: .volumeMounted, identity: identity, occurrence: occurrence, callbackToken: "baseline", semanticRole: .baseline),
        ])

        XCTAssertEqual(machine.classify(StorageRawEvent(kind: .diskDisappeared, identity: identity, occurrence: occurrence, callbackToken: "detach")), .transition)
        XCTAssertEqual(machine.classify(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "attach")), .transition)
        XCTAssertEqual(machine.classify(StorageRawEvent(kind: .volumeUnmounted, identity: identity, occurrence: occurrence, callbackToken: "unmount")), .transition)
        XCTAssertEqual(machine.classify(StorageRawEvent(kind: .volumeMounted, identity: identity, occurrence: occurrence, callbackToken: "mount")), .transition)
    }

    func testStorageStateMachineDistinguishesTransitionsAndRepeatedObservations() {
        let identity = StorageRawIdentity(volumeName: "Backup", filesystemPath: "/Volumes/Backup", serialNumber: nil, hardwareUUID: nil, mediaUUID: "backup-media", bsdName: "disk4s1", isWholeDisk: false)
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 1, quality: .exact)
        var machine = StorageStateMachine()
        let mounted = StorageRawEvent(kind: .volumeMounted, identity: identity, occurrence: occurrence, callbackToken: nil)
        let unmounted = StorageRawEvent(kind: .volumeUnmounted, identity: identity, occurrence: occurrence, callbackToken: nil)

        XCTAssertEqual(machine.classify(mounted), .transition)
        XCTAssertEqual(machine.classify(mounted), .confirmation)
        XCTAssertEqual(machine.classify(unmounted), .transition)
        XCTAssertEqual(machine.classify(unmounted), .confirmation)
        XCTAssertEqual(machine.classify(mounted), .transition)
    }

    func testStorageStateMachineDoesNotMergeUnavailableIdentities() {
        let identity = StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: nil, bsdName: nil, isWholeDisk: true)
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 1, quality: .exact)
        var machine = StorageStateMachine()

        XCTAssertEqual(machine.classify(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: nil)), .uncertain)
        XCTAssertTrue(machine.currentInventoryForTesting.isEmpty)
    }

    func testNativeStorageInitializationBuffersAmbiguousSnapshotCallbackAsUncertain() {
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 10, quality: .exact)
        let identity = StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: "disk7", isWholeDisk: true)
        let callback = StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "during-snapshot")
        let box = StorageAdapterBox()
        let provider = CallbackStorageInventoryProvider(snapshot: .available([])) {
            box.adapter?.receiveForTesting(callback)
        }
        let emissions = EmissionBox()
        let adapter = StorageEvidenceAdapter(
            clock: FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 10, processUptimeNanoseconds: 10),
            inventoryProvider: provider,
            emit: { emissions.append($0) }
        )
        box.adapter = adapter
        adapter.start()
        while !adapter.isReconciledForTesting {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        adapter.receiveForTesting(callback)
        adapter.stop()

        let roles = emissions.emissions.compactMap { emission -> StorageRawSemanticRole? in
            guard case let .raw(.storage(raw)) = emission else { return nil }
            guard raw.callbackToken == "during-snapshot" else { return nil }
            return raw.semanticRole
        }
        XCTAssertEqual(roles, [.uncertain, .transition])
        XCTAssertLessThanOrEqual(adapter.bufferHighWaterMarkForTesting, 256)
    }

    func testNativeStorageInitializationBufferHasHardBoundAndPreservesOrder() {
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 1, quality: .exact)
        let identity = StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: "disk7", isWholeDisk: true)
        var buffer = StorageInitializationBuffer(maximumEntries: 2)
        for index in 0 ..< 3 {
            buffer.append(StorageRawEvent(
                kind: .diskAppeared,
                identity: identity,
                occurrence: occurrence,
                callbackToken: "callback-\(index)"
            ))
        }

        XCTAssertEqual(buffer.entries.map(\.order), [1, 2])
        XCTAssertEqual(buffer.droppedCount, 1)
        XCTAssertEqual(buffer.drain().map(\.raw.callbackToken), ["callback-0", "callback-1"])
    }

    func testNativeStorageProviderUsesBoundedNativeSnapshotMetrics() {
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 1, quality: .exact)
        let snapshot = NativeStorageInventoryProvider(maximumEntities: 8).currentInventory(occurrence: occurrence)

        XCTAssertNotNil(snapshot.metrics.snapshotDurationNanoseconds)
        XCTAssertLessThanOrEqual(snapshot.metrics.diskCount, 8)
        XCTAssertLessThanOrEqual(snapshot.metrics.mountedVolumeCount, 8)
    }

    func testPowerNormalizerEmitsOnlyMeaningfulTransitions() {
        let ac = PowerRawState(externalPowerConnected: true, source: .ac, charging: false, currentCapacity: 80, maximumCapacity: 100)
        let battery = PowerRawState(externalPowerConnected: false, source: .battery, charging: false, currentCapacity: 79, maximumCapacity: 100)
        let charging = PowerRawState(externalPowerConnected: false, source: .battery, charging: true, currentCapacity: 79, maximumCapacity: 100)
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 2, quality: .exact)

        XCTAssertNotNil(PowerTransitionNormalizer.normalize(PowerRawTransition(previous: ac, current: battery, occurrence: occurrence)))
        XCTAssertNotNil(PowerTransitionNormalizer.normalize(PowerRawTransition(previous: battery, current: ac, occurrence: occurrence)))
        XCTAssertNotNil(PowerTransitionNormalizer.normalize(PowerRawTransition(previous: battery, current: charging, occurrence: occurrence)))
        XCTAssertNil(PowerTransitionNormalizer.normalize(PowerRawTransition(previous: ac, current: ac, occurrence: occurrence)))
    }

    func testNetworkNormalizerIsSupplementalAndCarriesNoPhysicalFailureOrSensitiveMetadata() throws {
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 3, quality: .exact)
        let previous = NetworkRawPath(status: .satisfied, interfaces: [.wifi])
        let current = NetworkRawPath(status: .unsatisfied, interfaces: [])
        let fact = try XCTUnwrap(NetworkPathNormalizer.normalize(NetworkRawTransition(previous: previous, current: current, occurrence: occurrence)))

        XCTAssertEqual(fact.sourceID, .network)
        XCTAssertEqual(fact.provenance.captureChannel, "NWPathMonitor")
        XCTAssertEqual(fact.attributes["supplemental"], .boolean(true))
        let observation = try ObservationFixtureFactory.observation(from: fact)
        let text = try String(decoding: observation.deterministicData(), as: UTF8.self)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("physical failure"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("ssid"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("mac address"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("ip address"))
    }

    func testRuntimeCreatesInMemoryObservationsWithMonotonicSourceSequences() async {
        let runtime = EvidenceRuntime(clock: FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 100, processUptimeNanoseconds: 100), adapterFactory: { _ in [] })
        runtime.start()
        defer { runtime.stop() }

        let identity = StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: nil, isWholeDisk: true)
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 100, quality: .exact)
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 24 {
                group.addTask {
                    _ = await runtime.ingest(.storage(StorageRawEvent(
                        kind: .diskAppeared,
                        identity: identity,
                        occurrence: occurrence,
                        callbackToken: "callback-\(index)"
                    )))
                }
            }
        }

        let observations = await runtime.journal.query(EvidenceJournalQuery(sourceID: .storage))
        XCTAssertEqual(observations.count, 24)
        XCTAssertEqual(observations.map(\.time.localSequence).sorted(), Array(1 ... 24).map(UInt64.init))
        XCTAssertEqual(Set(observations.map(\.time.correlationEpochID)).count, 1)
    }

    func testSleepWakeChangesEpochAndPrePostObservationsAreIncomparable() async throws {
        let runtime = EvidenceRuntime(clock: FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 100, processUptimeNanoseconds: 100), adapterFactory: { _ in [] })
        runtime.start()
        defer { runtime.stop() }
        let identity = StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: nil, isWholeDisk: true)
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 100, quality: .exact)
        let beforeValue = await runtime.ingest(.storage(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "before")))
        let before = try XCTUnwrap(beforeValue)

        _ = await runtime.ingest(.lifecycle(SleepWakeRawEvent(kind: .willSleep, observedAt: FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 100, processUptimeNanoseconds: 100).reading())))
        let afterSleepValue = await runtime.ingest(.storage(StorageRawEvent(kind: .diskDisappeared, identity: identity, occurrence: occurrence, callbackToken: "during")))
        let afterSleep = try XCTUnwrap(afterSleepValue)
        XCTAssertNotEqual(before.time.correlationEpochID, afterSleep.time.correlationEpochID)
        XCTAssertEqual(before.time.compare(to: afterSleep.time).relation, .incomparable)
        XCTAssertEqual(before.time.compare(to: afterSleep.time).basis, .none)

        _ = await runtime.ingest(.lifecycle(SleepWakeRawEvent(kind: .didWake, observedAt: FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 100, processUptimeNanoseconds: 100).reading())))
        let afterWakeValue = await runtime.ingest(.storage(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "after")))
        let afterWake = try XCTUnwrap(afterWakeValue)
        XCTAssertNotEqual(afterSleep.time.correlationEpochID, afterWake.time.correlationEpochID)
        let sleepObservations = await runtime.journal.query(EvidenceJournalQuery(sourceID: .sleepWake))
        XCTAssertEqual(sleepObservations.count, 0)
    }

    func testRuntimeStopsAdaptersAndIgnoresCallbacksAfterShutdown() async {
        let box = AdapterBox()
        let runtime = EvidenceRuntime(adapterFactory: { emit in
            let adapter = ManualEvidenceAdapter(sourceID: .storage)
            adapter.emitter = emit
            box.adapter = adapter
            return [adapter]
        })
        runtime.start()
        let adapter = box.adapter
        XCTAssertTrue(adapter?.started == true)
        runtime.stop()
        XCTAssertTrue(adapter?.stopped == true)
        adapter?.emit(.health(EvidenceSourceHealthUpdate(sourceID: .storage, event: .started, reason: .notObserved, suppressedCount: 0, observedAt: .now, detail: "late")))
        await runtime.drainForTesting()
        XCTAssertFalse(runtime.isRunning)
    }

    func testHealthyAdapterContinuesWhenAnotherAdapterReportsStartupFailure() async {
        let box = AdapterBox()
        let runtime = EvidenceRuntime(adapterFactory: { emit in
            let failed = ManualEvidenceAdapter(sourceID: .network, startupHealth: .startupFailure)
            let healthy = ManualEvidenceAdapter(sourceID: .storage)
            failed.emitter = emit
            healthy.emitter = emit
            box.adapter = healthy
            return [failed, healthy]
        })
        runtime.start()
        let identity = StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: nil, isWholeDisk: true)
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 4, quality: .exact)
        box.adapter?.emit(.raw(.storage(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "healthy"))))
        await runtime.drainForTesting()
        let storageObservations = await runtime.journal.query(EvidenceJournalQuery(sourceID: .storage))
        XCTAssertEqual(storageObservations.count, 1)
        runtime.stop()
    }

    func testNativeAdaptersRegisterAndCleanlyStopWithoutUserPrompts() {
        let emissions = EmissionBox()
        let adapters: [any Horizon2EvidenceAdapter] = [
            StorageEvidenceAdapter(emit: { emissions.append($0) }),
            PowerEvidenceAdapter(emit: { emissions.append($0) }),
            NetworkEvidenceAdapter(emit: { emissions.append($0) }),
            SleepWakeBoundaryAdapter(emit: { emissions.append($0) }),
        ]
        adapters.forEach { $0.start() }
        adapters.forEach { $0.stop() }
        XCTAssertTrue(adapters.allSatisfy { !$0.sourceID.rawValue.isEmpty })
    }

    func testApplicationLifecycleOwnsRuntimeInsteadOfWindowLifecycle() {
        let runtime = EvidenceRuntime(adapterFactory: { _ in [] }, enabled: false)
        let delegate = SmallMatterAppDelegate(evidenceRuntime: runtime)

        XCTAssertFalse(runtime.isRunning)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertTrue(runtime.isRunning)
        XCTAssertFalse(runtime.nativeCollectionEnabled)

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(runtime.isRunning)
    }

    func testGenerationBoundCallbackFromPreviousStartIsRejected() async {
        let callbacks = CallbackBox()
        let runtime = EvidenceRuntime(adapterFactory: { emit in
            callbacks.append(emit)
            return []
        })
        runtime.start()
        runtime.stop()
        runtime.start()
        defer { runtime.stop() }

        let identity = StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: nil, isWholeDisk: true)
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 10, quality: .exact)
        callbacks.callback(at: 0)?(.raw(.storage(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "stale"))))
        callbacks.callback(at: 1)?(.raw(.storage(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "current"))))
        await runtime.drainForTesting()

        let observations = await runtime.journal.query(EvidenceJournalQuery(sourceID: .storage))
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.attributes["lifecycle"], .string("diskAppeared"))
    }

    func testIngressOverflowIsVisibleAsIncompleteCapture() async {
        let journal = InMemoryEvidenceJournal()
        let runtime = EvidenceRuntime(
            journal: journal,
            adapterFactory: { _ in [] },
            ingressCapacity: 2
        )
        runtime.start()
        defer { runtime.stop() }
        let identity = StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: nil, isWholeDisk: true)
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 10, quality: .exact)
        for index in 0 ..< 512 {
            runtime.receive(.raw(.storage(StorageRawEvent(
                kind: .diskAppeared,
                identity: identity,
                occurrence: occurrence,
                callbackToken: "overflow-\(index)"
            ))))
        }
        for _ in 0 ..< 50 {
            let health = await journal.sourceHealth()
            if health.contains(where: { $0.reason == .incompleteCapture }) {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let health = await journal.sourceHealth()
        guard let overflow = health.first(where: { $0.reason == .incompleteCapture }) else {
            XCTFail("Expected a persisted count-limit overflow summary")
            return
        }
        XCTAssertGreaterThan(overflow.suppressedCount, 0)
        XCTAssertEqual(overflow.detail, Horizon2OverflowDiagnostic.detail(for: .countLimit))
        XCTAssertFalse(overflow.detail?.contains("reason.rawValue") == true)
    }

    func testPayloadOverflowHealthDetailUsesPayloadReasonWithoutSensitiveData() async throws {
        let journal = InMemoryEvidenceJournal()
        let runtime = EvidenceRuntime(journal: journal, adapterFactory: { _ in [] })
        runtime.start()
        defer { runtime.stop() }

        let identity = StorageRawIdentity(
            volumeName: nil,
            filesystemPath: "/Volumes/private-fixture",
            serialNumber: nil,
            hardwareUUID: nil,
            mediaUUID: String(repeating: "m", count: 9_000_000),
            bsdName: "disk9",
            isWholeDisk: true
        )
        runtime.receive(.raw(.storage(StorageRawEvent(
            kind: .diskAppeared,
            identity: identity,
            occurrence: EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 10, quality: .exact),
            callbackToken: "private-callback-token"
        ))))

        var overflow: EvidenceSourceHealthRecord?
        for _ in 0 ..< 50 {
            overflow = await journal.sourceHealth().first { $0.reason == .incompleteCapture }
            if overflow != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let record = try XCTUnwrap(overflow)
        XCTAssertEqual(record.suppressedCount, 1)
        XCTAssertEqual(record.detail, Horizon2OverflowDiagnostic.detail(for: .payloadLimit))
        XCTAssertFalse(record.detail?.contains("reason.rawValue") == true)
        XCTAssertFalse(record.detail?.contains("private-callback-token") == true)
        XCTAssertFalse(record.detail?.contains("/Volumes/private-fixture") == true)
        XCTAssertFalse(record.detail?.contains(String(repeating: "m", count: 32)) == true)
    }

    func testResidenceOverflowDiagnosticVocabularyIsBounded() {
        XCTAssertEqual(
            Horizon2OverflowDiagnostic.detail(for: .residenceLimit),
            "Bounded Horizon 2 ingress overflow (residence_limit); evidence is incomplete"
        )
        XCTAssertFalse(Horizon2OverflowDiagnostic.detail(for: .residenceLimit).contains("reason.rawValue"))
    }

    func testOverflowSummaryFlushesWhenOverflowLeavesNoRetainedBatch() async throws {
        let journal = InMemoryEvidenceJournal()
        let runtime = EvidenceRuntime(journal: journal, adapterFactory: { _ in [] }, ingressCapacity: 2)
        runtime.start()
        defer { runtime.stop() }

        for index in 0 ..< 512 {
            runtime.receive(.raw(.storage(storageEvent(token: "empty-drain-\(index)"))))
        }
        await runtime.drainForTesting()

        var overflow: EvidenceSourceHealthRecord?
        for _ in 0 ..< 50 {
            overflow = await journal.sourceHealth().first { $0.reason == .incompleteCapture }
            if overflow != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let record = try XCTUnwrap(overflow)
        XCTAssertGreaterThan(record.suppressedCount, 0)
        XCTAssertEqual(record.detail, Horizon2OverflowDiagnostic.detail(for: .countLimit))
    }

    func testRepeatedEpochsRetireSequenceBookkeeping() async {
        let runtime = EvidenceRuntime(adapterFactory: { _ in [] })
        runtime.start()
        defer { runtime.stop() }
        let reading = FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 10, processUptimeNanoseconds: 10).reading()
        for _ in 0 ..< 100 {
            _ = await runtime.ingest(.lifecycle(SleepWakeRawEvent(kind: .willSleep, observedAt: reading)))
            _ = await runtime.ingest(.lifecycle(SleepWakeRawEvent(kind: .didWake, observedAt: reading)))
        }
        let sequenceCount = await runtime.runtimeSequenceCountForTesting()
        XCTAssertEqual(sequenceCount, 0)
    }

    func testStorageWakeRequiresFreshBaselineBeforeEmittingTransition() {
        let emissions = EmissionBox()
        let clock = FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 10, processUptimeNanoseconds: 10)
        let adapter = StorageEvidenceAdapter(clock: clock, baselineSnapshotProvider: { _ in .available([]) }, emit: { emissions.append($0) })
        adapter.start()
        adapter.reconcileAfterWake()
        XCTAssertTrue(adapter.isReconciledForTesting)

        let raw = StorageRawEvent(
            kind: .diskAppeared,
            identity: StorageRawIdentity(volumeName: "Disk", filesystemPath: "/Volumes/Disk", serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: "disk2", isWholeDisk: true),
            occurrence: EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 10, quality: .exact),
            callbackToken: nil
        )
        adapter.receiveForTesting(raw)
        XCTAssertTrue(adapter.isReconciledForTesting)
        adapter.receiveForTesting(raw)
        adapter.stop()

        let rawCount = emissions.emissions.reduce(into: 0) { count, emission in
            if case .raw = emission {
                count += 1
            }
        }
        XCTAssertEqual(rawCount, 2)
        let roles = emissions.emissions.compactMap { emission -> StorageRawSemanticRole? in
            guard case let .raw(.storage(value)) = emission else { return nil }
            return value.semanticRole
        }
        XCTAssertEqual(roles, [.transition, .confirmation])
    }

    func testStorageStartupEnumerationEstablishesBaselineBeforeRealTransitions() {
        let emissions = EmissionBox()
        let adapter = StorageEvidenceAdapter(clock: FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 10, processUptimeNanoseconds: 10), baselineSnapshotProvider: { _ in .available([]) }, emit: { emissions.append($0) })
        adapter.start()
        while !adapter.isStartupBaselineEstablishedForTesting {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        let identity = StorageRawIdentity(volumeName: "Disk", filesystemPath: "/Volumes/Disk", serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: "disk2", isWholeDisk: true)
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 10, quality: .exact)
        adapter.receiveForTesting(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: nil))
        adapter.stop()

        let rawCount = emissions.emissions.reduce(into: 0) { count, emission in
            if case .raw = emission {
                count += 1
            }
        }
        let baselineHealth = emissions.emissions.compactMap { emission -> EvidenceSourceHealthUpdate? in
            guard case let .health(update) = emission else { return nil }
            return update
        }.first { $0.detail?.contains("Current storage baseline established") == true }
        XCTAssertEqual(rawCount, 1)
        XCTAssertNotNil(baselineHealth)
    }

    func testStorageInventoryParserRejectsMalformedInputWithoutCreatingBaseline() {
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 10, quality: .exact)
        let snapshot = StorageEvidenceAdapter.parseInventoryFixture(data: Data("not-a-plist".utf8), occurrence: occurrence)

        XCTAssertEqual(snapshot.failure, .malformedPropertyList)
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testStorageInventoryParserProducesSeparateDiskAndVolumeEntries() throws {
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 10, quality: .exact)
        let plist: [String: Any] = [
            "AllDisksAndPartitions": [
                [
                    "DeviceIdentifier": "disk4",
                    "DiskUUID": "whole-disk",
                    "Partitions": [
                        [
                            "DeviceIdentifier": "disk4s1",
                            "VolumeName": "Backup",
                            "VolumeUUID": "mounted-volume",
                            "MountPoint": "/Volumes/Backup",
                        ],
                    ],
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let snapshot = StorageEvidenceAdapter.parseInventoryFixture(data: data, occurrence: occurrence)

        XCTAssertNil(snapshot.failure)
        XCTAssertEqual(snapshot.events.filter { $0.entityClass == .disk }.count, 2)
        XCTAssertEqual(snapshot.events.filter { $0.entityClass == .volume }.count, 1)
        XCTAssertEqual(snapshot.events.count, 3)
        XCTAssertTrue(snapshot.events.allSatisfy { $0.semanticRole == .baseline })
    }

    func testStorageInventoryFailureKeepsCallbacksUncertain() {
        let emissions = EmissionBox()
        let adapter = StorageEvidenceAdapter(
            clock: FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 10, processUptimeNanoseconds: 10),
            baselineSnapshotProvider: { _ in .unavailable(.malformedPropertyList) },
            emit: { emissions.append($0) }
        )
        adapter.start()
        let identity = StorageRawIdentity(volumeName: "Disk", filesystemPath: "/Volumes/Disk", serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: "disk2", isWholeDisk: true)
        adapter.receiveForTesting(StorageRawEvent(
            kind: .diskAppeared,
            identity: identity,
            occurrence: EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 10, quality: .exact),
            callbackToken: nil
        ))
        adapter.stop()

        let rawEvents = emissions.emissions.compactMap { emission -> StorageRawEvent? in
            guard case let .raw(.storage(raw)) = emission else { return nil }
            return raw
        }
        XCTAssertEqual(rawEvents.last?.semanticRole, .uncertain)
        XCTAssertTrue(emissions.emissions.contains { emission in
            guard case let .health(update) = emission else { return false }
            return update.event == .sourceUnavailable && update.reason == .sourceUnavailable
        })
    }

    func testStorageDuplicateGateIsBoundedAndTokenReuseAfterRetirementIsNotSuppressed() {
        let identity = StorageRawIdentity(volumeName: "Disk", filesystemPath: "/Volumes/Disk", serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: "disk2", isWholeDisk: true)
        let occurrence = EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: 10, quality: .exact)
        var gate = StorageDuplicateGate(maximumEntries: 2)
        for token in ["one", "two"] {
            XCTAssertFalse(gate.shouldSuppress(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: token)))
        }
        XCTAssertTrue(gate.shouldSuppress(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "two")))
        XCTAssertFalse(gate.shouldSuppress(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "three")))
        XCTAssertFalse(gate.shouldSuppress(StorageRawEvent(kind: .diskAppeared, identity: identity, occurrence: occurrence, callbackToken: "one")))
        XCTAssertLessThanOrEqual(gate.countForTesting, 2)
    }

    func testHealthUsesInjectedEvidenceClock() {
        let emissions = EmissionBox()
        let clock = FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 10, processUptimeNanoseconds: 10)
        let adapter = NetworkEvidenceAdapter(clock: clock, emit: { emissions.append($0) })
        adapter.start()
        adapter.stop()
        let health = emissions.emissions.compactMap { emission -> EvidenceSourceHealthUpdate? in
            guard case let .health(update) = emission else { return nil }
            return update
        }
        XCTAssertFalse(health.isEmpty)
        XCTAssertTrue(health.allSatisfy { $0.observedAt == fixedDate })
    }

    func testConcurrentEnqueueAroundWorkerEmptyBoundaryDoesNotLoseWake() async {
        let runtime = EvidenceRuntime(clock: FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 10, processUptimeNanoseconds: 10), adapterFactory: { _ in [] })
        runtime.start()
        defer { runtime.stop() }

        for index in 0 ..< 100 {
            runtime.receive(.raw(.storage(storageEvent(token: "before-\(index)"))))
            await Task.yield()
            runtime.receive(.raw(.storage(storageEvent(token: "after-\(index)"))))
        }

        await runtime.drainForTesting()
        let observations = await runtime.journal.query(EvidenceJournalQuery(sourceID: .storage))
        XCTAssertEqual(observations.count, 200)
        XCTAssertEqual(runtime.ingressOverflowCountForTesting, 0)
    }

    func testSparseEventsPersistWithoutIndefiniteCoalescingDelay() async {
        let runtime = EvidenceRuntime(clock: FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 10, processUptimeNanoseconds: 10), adapterFactory: { _ in [] })
        runtime.start()
        defer { runtime.stop() }

        var latencies: [Double] = []
        for index in 0 ..< 100 {
            let start = DispatchTime.now().uptimeNanoseconds
            let observation = await runtime.ingest(.storage(storageEvent(token: "sparse-\(index)")))
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertNotNil(observation)
            latencies.append(Double(end - start) / 1_000_000.0)
        }

        let sorted = latencies.sorted()
        let p99 = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.99)) - 1)]
        XCTAssertLessThan(p99, 750)
        XCTAssertLessThanOrEqual(sorted.last ?? .infinity, 750)
    }

    func testIngressPayloadAccountingIsBoundedAndReturnsToZeroAfterDrain() async {
        let runtime = EvidenceRuntime(adapterFactory: { _ in [] })
        runtime.start()
        defer { runtime.stop() }

        for index in 0 ..< 512 {
            let identity = StorageRawIdentity(
                volumeName: nil,
                filesystemPath: nil,
                serialNumber: nil,
                hardwareUUID: nil,
                mediaUUID: String(repeating: "m", count: 20000) + "-\(index)",
                bsdName: nil,
                isWholeDisk: true
            )
            runtime.receive(.raw(.storage(StorageRawEvent(
                kind: .diskAppeared,
                identity: identity,
                occurrence: EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: UInt64(index), quality: .exact),
                callbackToken: "payload-\(index)"
            ))))
        }

        await runtime.drainForTesting()
        XCTAssertLessThanOrEqual(
            runtime.ingressPeakQueuedPayloadBytesForTesting,
            Horizon2EvidenceConfiguration.combinedQueuePayloadMaximumBytes
        )
        XCTAssertEqual(runtime.ingressQueuedPayloadBytesForTesting, 0)
    }

    func testIngressCountAndPayloadBoundsRemainIndependent() async {
        let runtime = EvidenceRuntime(adapterFactory: { _ in [] }, ingressCapacity: 2)
        runtime.start()
        defer { runtime.stop() }

        for index in 0 ..< 32 {
            runtime.receive(.raw(.storage(storageEvent(token: "bounded-\(index)"))))
        }
        await runtime.drainForTesting()

        XCTAssertEqual(runtime.ingressQueuedPayloadBytesForTesting, 0)
        XCTAssertGreaterThan(runtime.ingressTotalOverflowCountForTesting, 0)
    }

    func testMixedLifecycleBoundaryBatchPreservesPreAndPostWakeEpochs() async {
        let runtime = EvidenceRuntime(clock: FixedEvidenceClock(wallTime: fixedDate, continuousNanoseconds: 10, processUptimeNanoseconds: 10), adapterFactory: { _ in [] })
        runtime.start()
        defer { runtime.stop() }

        runtime.receive(.raw(.storage(storageEvent(token: "pre-boundary", continuousNanoseconds: 10))))
        runtime.receive(.raw(.lifecycle(SleepWakeRawEvent(kind: .willSleep, observedAt: nil))))
        runtime.receive(.raw(.lifecycle(SleepWakeRawEvent(kind: .didWake, observedAt: nil))))
        runtime.receive(.raw(.storage(storageEvent(token: "post-boundary", continuousNanoseconds: 20))))

        await runtime.drainForTesting()
        let observations = await runtime.journal.query(EvidenceJournalQuery(sourceID: .storage))
        XCTAssertEqual(observations.count, 2)
        let ordered = observations.sorted {
            ($0.time.sourceOccurrence?.continuousNanoseconds ?? 0) < ($1.time.sourceOccurrence?.continuousNanoseconds ?? 0)
        }
        XCTAssertNotEqual(ordered[0].time.correlationEpochID, ordered[1].time.correlationEpochID)
        XCTAssertEqual(ordered.map(\.time.localSequence), [1, 1])
    }

    private func storageEvent(token: String, continuousNanoseconds: UInt64 = 10) -> StorageRawEvent {
        StorageRawEvent(
            kind: .diskAppeared,
            identity: StorageRawIdentity(volumeName: nil, filesystemPath: nil, serialNumber: nil, hardwareUUID: nil, mediaUUID: "media", bsdName: nil, isWholeDisk: true),
            occurrence: EvidenceSourceOccurrence(wallTime: fixedDate, continuousNanoseconds: continuousNanoseconds, quality: .exact),
            callbackToken: token
        )
    }
}

private final class StorageAdapterBox: @unchecked Sendable {
    weak var adapter: StorageEvidenceAdapter?
}

private final class CallbackStorageInventoryProvider: StorageInventoryProviding, @unchecked Sendable {
    private let snapshot: StorageInventorySnapshot
    private let onSnapshot: @Sendable () -> Void

    init(snapshot: StorageInventorySnapshot, onSnapshot: @escaping @Sendable () -> Void) {
        self.snapshot = snapshot
        self.onSnapshot = onSnapshot
    }

    func currentInventory(occurrence _: EvidenceSourceOccurrence) -> StorageInventorySnapshot {
        onSnapshot()
        return snapshot
    }
}

private final class AdapterBox: @unchecked Sendable {
    var adapter: ManualEvidenceAdapter?
}

private final class CallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable (EvidenceAdapterEmission) -> Void] = []

    func append(_ callback: @escaping @Sendable (EvidenceAdapterEmission) -> Void) {
        lock.lock()
        callbacks.append(callback)
        lock.unlock()
    }

    func callback(at index: Int) -> (@Sendable (EvidenceAdapterEmission) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard callbacks.indices.contains(index) else { return nil }
        return callbacks[index]
    }
}

private final class EmissionBox: @unchecked Sendable {
    private(set) var emissions: [EvidenceAdapterEmission] = []

    func append(_ emission: EvidenceAdapterEmission) {
        emissions.append(emission)
    }
}

private final class ManualEvidenceAdapter: Horizon2EvidenceAdapter, @unchecked Sendable {
    let sourceID: Horizon2SourceID
    let startupHealth: EvidenceSourceHealthEvent?
    var emitter: (@Sendable (EvidenceAdapterEmission) -> Void)?
    private(set) var started = false
    private(set) var stopped = false

    init(sourceID: Horizon2SourceID, startupHealth: EvidenceSourceHealthEvent? = nil) {
        self.sourceID = sourceID
        self.startupHealth = startupHealth
    }

    func start() {
        started = true
        if let startupHealth {
            emitter?(.health(EvidenceSourceHealthUpdate(sourceID: sourceID, event: startupHealth, reason: .permissionOrAPIUnavailable, suppressedCount: 0, observedAt: .now, detail: "fake startup failure")))
        }
    }

    func stop() {
        stopped = true
    }

    func reconcileAfterWake() {}

    func emit(_ emission: EvidenceAdapterEmission) {
        emitter?(emission)
    }
}

private enum ObservationFixtureFactory {
    static func observation(from fact: NormalizedEvidenceFact) throws -> Observation {
        let time = EvidenceTime(
            observedWallTime: fact.sourceOccurrence?.wallTime ?? .now,
            continuousNanoseconds: fact.sourceOccurrence?.continuousNanoseconds,
            processUptimeNanoseconds: nil,
            processRunID: UUID(),
            bootSessionID: "fixture-boot",
            localSequence: 1,
            sourceTimestampQuality: fact.provenance.sourceTimestampQuality,
            orderingDomain: EvidenceOrderingDomain(sourceID: fact.sourceID, processRunID: UUID(), clockDomainID: "fixture"),
            sourceOccurrence: fact.sourceOccurrence
        )
        return Observation(
            id: UUID(),
            domain: fact.domain,
            eventKind: fact.eventKind,
            sourceID: fact.sourceID,
            subject: fact.subject,
            provenance: fact.provenance,
            time: time,
            availability: fact.availability,
            previousState: fact.previousState,
            currentState: fact.currentState,
            attributes: fact.attributes
        )
    }
}

// swiftlint:enable line_length trailing_comma identifier_name optional_data_string_conversion file_length
