import Foundation

struct EvidenceIngressItem: Sendable {
    let emission: EvidenceAdapterEmission
    let generation: UInt64
    let capturedAt: EvidenceClockReading
    let completion: (@Sendable (Observation?) -> Void)?
    let enqueuedAtContinuousNanoseconds: UInt64
}

enum Horizon2IngressOverflowReason: String, Codable, Hashable, Sendable {
    case countLimit = "count_limit"
    case payloadLimit = "payload_limit"
    case residenceLimit = "residence_limit"
}

struct Horizon2OverflowKey: Hashable, Sendable {
    let sourceID: Horizon2SourceID
    let reason: Horizon2IngressOverflowReason
}

struct Horizon2DroppedIngress: Sendable {
    let item: EvidenceIngressItem
    let reason: Horizon2IngressOverflowReason
}

struct PendingNormalizedObservation {
    let index: Int
    let observation: Observation
    let fact: NormalizedEvidenceFact
}

final class ObservationCompletion: @unchecked Sendable {
    private let continuation: CheckedContinuation<Observation?, Never>

    init(_ continuation: CheckedContinuation<Observation?, Never>) {
        self.continuation = continuation
    }

    func resume(_ observation: Observation?) {
        continuation.resume(returning: observation)
    }
}
