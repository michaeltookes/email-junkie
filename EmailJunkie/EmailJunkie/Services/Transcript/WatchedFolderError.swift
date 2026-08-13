import Foundation

/// A watched-folder failure surfaced to the owner so the UI never claims to be
/// watching a folder it can't actually reach (item 51).
enum WatchedFolderError: Error, Equatable {
    /// The folder couldn't be opened for watching (missing, or no permission).
    case cannotOpenFolder(String)
    /// The folder was renamed or deleted while watching and can't be re-opened.
    case folderUnavailable(String)
}
