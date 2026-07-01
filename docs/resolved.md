# Email Junkie - Resolved Items

Completed backlog items, most recent first. Item numbers are the stable IDs from `docs/backlog.md` and are not reused.

### ~~1: macOS menu-bar app shell~~
**Resolved**: 2026-06-30 (commit 8f1fef8, branch feature/menu-bar-shell)
**Description**: Scaffolded the native SwiftUI menu-bar app (`LSUIElement`, no Dock icon) mirroring the Prompter structure. Ships an `NSStatusItem` menu with a live status line, Settings…, a working Launch-at-Login toggle (`SMAppService`), a Check-for-Updates entry (stubbed until the distribution milestone), and Quit; an `AppState` with injectable persistence and debounced settings save; and a SwiftUI Settings window with working controls plus placeholders for the account/AI features. Xcode 26 project uses a file-system-synchronized root group, targets macOS 14 / Swift 5. Builds clean (universal arm64+x86_64) and passes SwiftLint.
