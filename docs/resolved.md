# Email Junkie - Resolved Items

Completed backlog items, most recent first. Item numbers are the stable IDs from `docs/backlog.md` and are not reused.

### ~~10: Secure local storage~~
**Resolved**: 2026-07-02 (branch secure-local-storage)
**Description**: Added a protocol-based `SecretStore` with a `KeychainStore` (macOS Keychain generic-password items, after-first-unlock/device-only, no entitlement) and an `InMemorySecretStore` for tests/previews, plus typed `SecretKey`s for Gmail tokens, BYO Google client credentials, and per-provider LLM keys. Secrets never touch the plaintext settings file; app state stays in local JSON. Added a Privacy section to Settings stating the local-first posture. 19 tests (in-memory contract tests always run; real-Keychain tests probe and skip where unavailable). Fixed `removeAll` to loop `SecItemDelete` (macOS deletes one match per call). Note: the disconnect UI lands with item 3 and the onboarding privacy display with item 2; the storage primitives and Settings statement are done.

### ~~15: CI pipeline (build, test, lint on push/PR)~~
**Resolved**: 2026-07-01 (branch ci-oss)
**Description**: Added a GitHub Actions workflow (`.github/workflows/ci.yml`) that runs on every push and PR to main: SwiftLint in strict mode, then `xcodebuild test` on a macOS runner (no signing required). Added an `EmailJunkieTests` unit-test target so CI has real tests to run, and restricted the workflow token to read-only. Enforcing required status checks (branch protection) and dependency caching are tracked as a follow-up (item 38).

### ~~14: Open-source repo scaffolding~~
**Resolved**: 2026-07-01 (branch ci-oss)
**Description**: Added an MIT `LICENSE`, a real `README` (overview, local-first/BYO-key principles, planned features, build-from-source), `CONTRIBUTING.md`, a Contributor Covenant `CODE_OF_CONDUCT.md`, bug/feature issue templates, and a pull-request template.

### ~~1: macOS menu-bar app shell~~
**Resolved**: 2026-06-30 (commit 8f1fef8, branch feature/menu-bar-shell)
**Description**: Scaffolded the native SwiftUI menu-bar app (`LSUIElement`, no Dock icon) mirroring the Prompter structure. Ships an `NSStatusItem` menu with a live status line, Settings…, a working Launch-at-Login toggle (`SMAppService`), a Check-for-Updates entry (stubbed until the distribution milestone), and Quit; an `AppState` with injectable persistence and debounced settings save; and a SwiftUI Settings window with working controls plus placeholders for the account/AI features. Xcode 26 project uses a file-system-synchronized root group, targets macOS 14 / Swift 5. Builds clean (universal arm64+x86_64) and passes SwiftLint.
