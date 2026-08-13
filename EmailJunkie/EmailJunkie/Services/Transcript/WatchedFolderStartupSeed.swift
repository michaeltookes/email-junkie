import Foundation

enum WatchedFolderStartupSeed {
    static func canEstablishInitialBaseline(discoveryIsComplete: Bool) -> Bool {
        discoveryIsComplete
    }

    static func existedBeforeStartup(_ url: URL, startedAt startupBoundary: Date) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]) else {
            return false
        }
        return existedBeforeStartup(
            addedToDirectoryDate: values.addedToDirectoryDate,
            startedAt: startupBoundary
        )
    }

    static func existedBeforeStartup(
        addedToDirectoryDate: Date?,
        startedAt startupBoundary: Date
    ) -> Bool {
        guard let addedToDirectoryDate else { return true }
        return addedToDirectoryDate <= startupBoundary
    }
}
