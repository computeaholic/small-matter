import Foundation

enum RecentChangesProjection {
    static func isRecentChangesRelevant(_ observation: Observation) -> Bool {
        switch observation.eventKind {
        case .storageDiskLifecycle, .storageMountLifecycle:
            // Routine storage churn is retained in evidence but is not a meaningful
            // Recent Changes row. Exceptional availability must remain visible so a
            // missing identity or source-health problem cannot be hidden by this UI
            // projection.
            switch observation.availability {
            case .available:
                return false
            case .unavailable, .unknown:
                return IncidentChangeProjection.isUserVisibleChange(observation)
            }
        default:
            return IncidentChangeProjection.isUserVisibleChange(observation)
        }
    }
}
