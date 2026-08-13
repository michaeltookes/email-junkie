import Foundation

enum WatchedFolderStartupSeed {
    static func existedBeforeStartup(
        addedToDirectoryDate: Date?,
        startedAt startupBoundary: Date
    ) -> Bool {
        guard let addedToDirectoryDate else { return false }
        return addedToDirectoryDate <= startupBoundary
    }
}
