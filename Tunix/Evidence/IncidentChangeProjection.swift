import Foundation

enum IncidentChangeProjection {
    static func userVisibleObservations(_ observations: [Observation]) -> [Observation] {
        observations.filter(isUserVisibleChange)
    }

    static func isUserVisibleChange(_ observation: Observation) -> Bool {
        if observation.sourceID == .storage, let role = semanticRole(for: observation) {
            switch role {
            case .baseline, .confirmation, .uncertain:
                return false
            case .transition:
                return true
            }
        }

        switch observation.eventKind {
        case .powerSourceTransition, .networkPathTransition:
            return true
        case .storageDiskLifecycle, .storageMountLifecycle:
            return true
        case .sleepWakeBoundary, .sourceUnavailable, .sourceSuppressed, .unknown:
            return false
        }
    }

    static func semanticRole(for observation: Observation) -> StorageRawSemanticRole? {
        guard observation.sourceID == .storage,
              let value = observation.attributes["semanticRole"],
              case let .string(rawValue) = value
        else {
            return nil
        }
        return StorageRawSemanticRole(rawValue: rawValue)
    }
}
