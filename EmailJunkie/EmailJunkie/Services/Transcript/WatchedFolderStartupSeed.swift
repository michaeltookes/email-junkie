import Foundation

enum WatchedFolderStartupSeed {
    static func existedBeforeStartup(
        addedToDirectoryDate: Date?,
        startedAt startupBoundary: Date
    ) -> Bool {
        guard let addedToDirectoryDate else { return true }
        return addedToDirectoryDate <= startupBoundary
    }
}
