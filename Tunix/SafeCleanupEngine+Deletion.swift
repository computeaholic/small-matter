import Foundation

enum CleanupCandidateDeletionOutcome {
    case deleted
    case stale(String)
    case failed(String)
}

extension SafeCleanupEngine {
    func observedSpaceReclaimed(before: UInt64?, after: UInt64?) -> UInt64? {
        guard let before, let after else { return nil }
        return after > before ? after - before : 0
    }

    func delete(
        candidate: CleanupCandidate,
        root: CleanupRoot,
        beforeEachDelete: ((CleanupCandidate) -> Void)?
    ) -> CleanupCandidateDeletionOutcome {
        let url = URL(fileURLWithPath: candidate.path)
        guard storage.exists(at: url) else { return .stale("No longer present") }
        guard isCanonicalDescendant(url, of: root), rootIdentityMatches(candidate, root: root)
        else { return .stale("Path changed outside approved scope") }
        if let processBlockReason = developmentProcessBlockReason(for: root) {
            return .stale(processBlockReason)
        }
        guard fingerprintMatches(candidate, at: url) else { return .stale("Changed after scan") }

        beforeEachDelete?(candidate)
        guard isCanonicalDescendant(url, of: root), rootIdentityMatches(candidate, root: root)
        else { return .stale("Path changed outside approved scope") }
        if let processBlockReason = developmentProcessBlockReason(for: root) {
            return .stale(processBlockReason)
        }
        guard fingerprintMatches(candidate, at: url) else { return .stale("Changed before deletion") }

        do {
            try storage.deleteItem(
                at: url,
                relativeTo: root.url,
                expectedFingerprint: candidate.fingerprint
            )
            return storage.exists(at: url)
                ? .failed("Deletion could not be verified")
                : .deleted
        } catch {
            return .failed("Permission or filesystem failure")
        }
    }

    private func developmentProcessBlockReason(for root: CleanupRoot) -> String? {
        guard root.scope == .xcodeDerivedData else { return nil }
        let snapshot = developmentProcessSnapshot()
        guard snapshot.isComplete else { return "Development-process detection unavailable" }
        return snapshot.names.isEmpty ? nil : "Active development process detected"
    }

    private func fingerprintMatches(_ candidate: CleanupCandidate, at url: URL) -> Bool {
        guard let metadata = try? storage.metadata(for: url) else { return false }
        return metadata.fingerprint == candidate.fingerprint
    }

    private func isCanonicalDescendant(_ item: URL, of root: CleanupRoot) -> Bool {
        let standardizedRoot = root.url.standardizedFileURL
        let standardizedItem = item.standardizedFileURL
        guard standardizedRoot.resolvingSymlinksInPath().standardizedFileURL.path == standardizedRoot.path,
              isDescendant(standardizedItem, of: standardizedRoot),
              standardizedItem.resolvingSymlinksInPath().standardizedFileURL.path == standardizedItem.path
        else { return false }
        return true
    }

    func isDescendant(_ item: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let itemPath = item.standardizedFileURL.path
        return itemPath.hasPrefix(rootPath + "/")
    }

    private func rootIdentityMatches(_ candidate: CleanupCandidate, root: CleanupRoot) -> Bool {
        guard let expected = candidate.approvedRootResourceIdentifier,
              let current = try? storage.metadata(for: root.url).resourceIdentifier
        else { return false }
        return expected == current
    }
}
