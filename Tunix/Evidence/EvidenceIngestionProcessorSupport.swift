import Foundation

#if HORIZON2_MEASUREMENT
    private extension EvidenceIngestionProcessor {
        func failureCategory(_ error: Error) -> String {
            switch error as? EvidenceJournalError {
            case .capacityUnavailable:
                return "journal_capacity_unavailable"
            case .oversizedRecord:
                return "oversized_record"
            case .observationPayloadMismatch:
                return "observation_payload_mismatch"
            case .unavailable:
                return "journal_unavailable"
            case .none:
                return "other"
            }
        }
    }
#endif
