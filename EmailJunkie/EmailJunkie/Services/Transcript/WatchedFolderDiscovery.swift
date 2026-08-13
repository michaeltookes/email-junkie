import Foundation

struct WatchedFolderDiscoveryResult {
    var urls: [URL]
    var isComplete: Bool
}

enum WatchedFolderDiscovery {

    static func currentContents(folderURL: URL, fileManager: FileManager) async -> WatchedFolderDiscoveryResult {
        await Task.detached(priority: .utility) {
            currentContentsSync(folderURL: folderURL, fileManager: fileManager)
        }.value
    }

    static func currentContentsSync(folderURL: URL, fileManager: FileManager) -> WatchedFolderDiscoveryResult {
        let recursive = currentRecursiveURLs(folderURL: folderURL, fileManager: fileManager)
        var isComplete = recursive.isComplete
        let urls = recursive.urls.filter { url in
            guard let isDirectory = isDirectory(url) else {
                isComplete = false
                return false
            }
            return !isDirectory
        }
        return WatchedFolderDiscoveryResult(urls: urls, isComplete: isComplete)
    }

    private static func currentRecursiveURLs(
        folderURL: URL,
        fileManager: FileManager
    ) -> WatchedFolderDiscoveryResult {
        var isComplete = true
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                isComplete = false
                return true
            }
        ) else {
            return WatchedFolderDiscoveryResult(urls: [], isComplete: false)
        }
        let urls = enumerator.compactMap { $0 as? URL }
            .sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        return WatchedFolderDiscoveryResult(urls: urls, isComplete: isComplete)
    }

    private static func isDirectory(_ url: URL) -> Bool? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
            return nil
        }
        return values.isDirectory == true
    }
}
