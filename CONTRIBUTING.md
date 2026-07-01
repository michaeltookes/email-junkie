# Contributing to Email Junkie

Thanks for your interest in contributing! This is an early-stage, local-first,
open-source macOS app. Contributions of all kinds are welcome — bug reports,
features, docs, and tests.

## Getting set up

**Requirements**

- macOS 14 (Sonoma) or later
- Xcode 16 or later
- [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`)

**Build & run**

```bash
git clone https://github.com/michaeltookes/email-junkie.git
cd email-junkie/EmailJunkie
open EmailJunkie.xcodeproj   # select the "EmailJunkie" scheme and run
```

**Test & lint from the command line**

```bash
cd EmailJunkie
xcodebuild test -project EmailJunkie.xcodeproj -scheme EmailJunkie \
  -destination 'platform=macOS'
swiftlint lint --strict      # run from the EmailJunkie/ directory
```

## Project layout

```
EmailJunkie/
├─ EmailJunkie.xcodeproj      # Xcode 16 project (file-system-synchronized groups)
├─ EmailJunkie/              # app sources
│  ├─ App/                   # entry point, AppDelegate, AppState, menu bar
│  ├─ Services/              # persistence, updates, login item
│  ├─ Models/                # data models
│  ├─ Views/                 # SwiftUI views
│  └─ Utilities/
└─ EmailJunkieTests/         # unit tests
docs/
├─ backlog.md                # prioritized roadmap (item numbers are stable IDs)
└─ resolved.md               # completed items
```

The project uses Xcode 16 file-system-synchronized groups, so **adding a Swift
file to a source folder automatically includes it in the target** — no project
file edits needed.

## Making changes

1. **Branch off `main`** with a descriptive name (e.g. `feature/gmail-oauth`).
2. **Keep commits focused** — one logical change per commit, imperative subject.
3. **Match the surrounding style.** Swift code should pass `swiftlint --strict`.
4. **Add tests** for logic where practical; put them in `EmailJunkieTests/`.
5. **Pick up a backlog item.** See [`docs/backlog.md`](docs/backlog.md); reference
   the item number in your PR.

## Pull requests

- Ensure **CI is green** (build, tests, and SwiftLint all pass) before requesting
  review.
- Fill out the pull-request template.
- PRs are reviewed (this repo uses automated review); please respond to feedback.
- By contributing, you agree your contributions are licensed under the
  [MIT License](LICENSE).

## Reporting bugs & requesting features

Use the issue templates. For bugs, include your macOS version and steps to
reproduce. Please **never include email contents, API keys, or OAuth tokens** in
an issue.
