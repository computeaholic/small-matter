#if HORIZON2_MEASUREMENT
    import Foundation

    private extension Horizon2MeasurementDriver {
        private func loadRecords(from url: URL) throws -> [NormalizedRecord] {
            let data = try Data(contentsOf: url)
            guard let content = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "Horizon2Measurement", code: 1)
            }
            let lines = content.split(whereSeparator: \.isNewline)
            return try lines.map { line in
                guard let data = line.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sourceID = object["source_id"] as? String,
                      let eventName = object["event_name"] as? String,
                      let wall = object["captured_at_wall"] as? String,
                      let wallTime = ISO8601DateFormatter().date(from: wall)
                else { throw NSError(domain: "Horizon2Measurement", code: 1) }
                let payload = ((object["payload"] as? [String: Any])?["payload"] as? [String: Any]) ?? [:]
                let status = NetworkPathStatus(
                    rawValue: ((payload["status"] as? String) ?? "SATISFIED").uppercased()
                ) ?? .satisfied
                let interfaceNames = payload["uses_interface_types"] as? [String] ?? ["other"]
                let interfaces = Set(interfaceNames.compactMap { NetworkInterfaceFact(rawValue: $0.uppercased()) })
                return NormalizedRecord(
                    sourceID: sourceID,
                    eventName: eventName,
                    capturedAt: EvidenceSourceOccurrence(
                        wallTime: wallTime,
                        continuousNanoseconds: object["captured_at_continuous_ns"] as? UInt64,
                        quality: .exact
                    ),
                    identityDigest: payload["identity_digest"] as? String,
                    status: status,
                    interfaces: interfaces.isEmpty ? [.other] : interfaces
                )
            }
        }

        // Why: ordered canonical flow.
        // Why: ordered canonical flow.
        // swiftlint:disable:next function_body_length
        private func makeRawEvent(_ record: NormalizedRecord) -> Horizon2RawEvent? {
            switch record.sourceID {
            case Horizon2SourceID.storage.rawValue:
                let kind: StorageRawEventKind
                if record.eventName.contains("disk_disappeared") {
                    kind = .diskDisappeared
                } else if record.eventName.contains("volume_mounted") {
                    kind = .volumeMounted
                } else if record.eventName.contains("volume_unmounted") {
                    kind = .volumeUnmounted
                } else {
                    kind = .diskAppeared
                }
                return .storage(StorageRawEvent(
                    kind: kind,
                    identity: StorageRawIdentity(
                        volumeName: nil,
                        filesystemPath: nil,
                        serialNumber: nil,
                        hardwareUUID: nil,
                        mediaUUID: record.identityDigest,
                        bsdName: nil,
                        isWholeDisk: true
                    ),
                    occurrence: record.capturedAt,
                    callbackToken: record.identityDigest
                ))
            case Horizon2SourceID.network.rawValue:
                let previous = NetworkRawPath(status: .unsatisfied, interfaces: [.other])
                let current = NetworkRawPath(
                    status: record.status,
                    interfaces: record.interfaces
                )
                return .network(NetworkRawTransition(
                    previous: previous,
                    current: current,
                    occurrence: record.capturedAt
                ))
            case Horizon2SourceID.power.rawValue:
                let previous = PowerRawState(
                    externalPowerConnected: false,
                    source: .battery,
                    charging: false,
                    currentCapacity: 50,
                    maximumCapacity: 100
                )
                let current = PowerRawState(
                    externalPowerConnected: true,
                    source: .acPower,
                    charging: false,
                    currentCapacity: 80,
                    maximumCapacity: 100
                )
                return .power(PowerRawTransition(previous: previous, current: current, occurrence: record.capturedAt))
            default:
                return nil
            }
        }

        private func packageCosts(incidentID: UUID,
                                  journal: any EvidenceJournal) async throws -> Horizon2MeasurementPackageCosts {
            let assemblyStart = DispatchTime.now().uptimeNanoseconds
            let package = try await EvidencePackageAssembler().assemble(incidentID: incidentID, journal: journal)
            let assemblyMilliseconds = milliseconds(since: assemblyStart)
            let jsonStart = DispatchTime.now().uptimeNanoseconds
            let json = try EvidencePackageJSONRenderer.render(package)
            let jsonMilliseconds = milliseconds(since: jsonStart)
            let textStart = DispatchTime.now().uptimeNanoseconds
            let text = try EvidencePackageTextRenderer.render(package)
            let textMilliseconds = milliseconds(since: textStart)
            let previewStart = DispatchTime.now().uptimeNanoseconds
            _ = try EvidenceExportPreviewModel(package: package)
            let previewMilliseconds = milliseconds(since: previewStart)
            return Horizon2MeasurementPackageCosts(
                assemblyMilliseconds: assemblyMilliseconds,
                jsonMilliseconds: jsonMilliseconds,
                textMilliseconds: textMilliseconds,
                previewMilliseconds: previewMilliseconds,
                jsonBytes: json.count,
                textBytes: text.utf8.count
            )
        }

        private func sourceEventCounts(_ records: [NormalizedRecord]) -> [String: Int] {
            records.reduce(into: [:]) { counts, record in
                counts["\(record.sourceID):\(record.eventName)", default: 0] += 1
            }
        }

        private static let representativeTransitionEventNames: Set<String> = [
            "storage.disk_appeared",
            "power.source_change",
            "network.path_update"
        ]

        private func writePhase(_ phase: String, configuration: Horizon2MeasurementConfiguration) {
            guard let phaseURL = configuration.phaseURL else { return }
            let payload = "\(phase) \(DispatchTime.now().uptimeNanoseconds) \(Date().timeIntervalSince1970)\n"
            try? FileManager.default.createDirectory(
                at: phaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data(payload.utf8)
            if FileManager.default.fileExists(atPath: phaseURL.path) {
                do {
                    let handle = try FileHandle(forWritingTo: phaseURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    // Measurement markers are diagnostic only and must never
                    // affect the production evidence path.
                }
            } else {
                try? data.write(to: phaseURL, options: .atomic)
            }
        }

        private func milliseconds(since start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        }
    }
#endif
