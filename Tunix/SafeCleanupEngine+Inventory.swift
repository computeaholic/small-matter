import Foundation

extension SafeCleanupEngine {
    func sameFileSystem(_ itemIdentifier: String?, _ rootIdentifier: String) -> Bool {
        guard let itemIdentifier,
              let itemDevice = itemIdentifier.split(separator: ":", maxSplits: 1).first,
              let rootDevice = rootIdentifier.split(separator: ":", maxSplits: 1).first
        else { return false }
        return itemDevice == rootDevice
    }
}
