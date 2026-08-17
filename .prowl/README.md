# Prowl hunts for Sentwise (experimental macOS target)

End-to-end QA hunts that drive the real Sentwise menu bar app through macOS
Accessibility (Prowl's experimental `macos` target, unreleased — requires the
locally-linked CLI, not the npm `prowl-tools` package).

## One-time setup

1. **CLI**: in the prowl repo, `npm run build && npm link` — puts `prowl` on
   your PATH pointing at the local build.
2. **Helper**: in the prowl repo, `cd macdriver && swift build -c release`.
   The linked CLI finds the binary automatically (or set `PROWL_MACDRIVER_BIN`).
3. **Permissions** (System Settings → Privacy & Security), granted to the
   terminal app you run `prowl` from:
   - **Accessibility** — required for everything.
   - **Screen Recording** — only needed for screenshot steps / failure
     screenshots.
4. **Build the app under test** from this checkout. The Prowl config points at
   this deterministic build product so hunts do not exercise an older installed
   Sentwise build:

   ```bash
   xcodebuild build \
     -project Sentwise/Sentwise.xcodeproj \
     -scheme Sentwise \
     -configuration Debug \
     -derivedDataPath .prowl/DerivedData \
     CODE_SIGNING_ALLOWED=NO
   ```

## Running

From the repo root:

```bash
prowl list
prowl run menu-smoke          # status-item menu opens; all safe actions exist
prowl run follow-up-composer  # flagship: New Follow-up window opens
prowl run review-drafts       # approval surface: Review Drafts window opens
prowl run browse-mailbox      # Browse Mailbox window opens
prowl run setup-assistant     # onboarding window opens (item 64 surface)
prowl run settings-window     # Settings window opens (item 65 surface)
prowl run activity-history    # Activity History window opens
```

Each run launches the Sentwise app at
`.prowl/DerivedData/Build/Products/Debug/Sentwise.app`, drives it, and quits it
afterward. That bundle path automatically enables Sentwise's Prowl hunt mode
before app startup automation runs. Artifacts land in `.prowl/runs/`
(gitignored).

## Hunt mode: isolation + seeded fixture

Hunt mode (see `Sentwise/Sentwise/App/ProwlHuntRuntime.swift`) isolates runs
from the user's live Sentwise profile: settings, processed-message state,
pending drafts, activity history, voice profile, and secrets use in-memory
stores instead of Application Support and Keychain. Startup side effects are
disabled before UI is presented: Sparkle startup, notification authorization,
reachability monitoring, inbox watcher auto-resume, transcript-folder watcher
auto-resume, and first-run onboarding auto-open.

The in-memory stores are **seeded with a fake connected account** so the
account-gated menu surfaces exist and hunts can open every product window:

- Account `hunt.fixture@sentwise.invalid` on host `imap.sentwise.invalid` —
  the `.invalid` TLD (RFC 2606) never resolves, so nothing in the fixture can
  reach a real mail server. This unlocks **New Follow-up from Transcript** and
  **Browse Mailbox** (whose connection attempt fails fast and harmlessly).
- One pending fixture draft, which unlocks **Review Drafts (1)**.
- Onboarding marked complete, so the menu is in its normal steady state.
- **No LLM key and no verified model**, so watching stays unavailable and no
  provider can be called.

The `.prowl/DerivedData` app path is part of that safety boundary. If you point
`target.app` somewhere else, do not present the hunts as live-account-safe
unless that build is launched with `SENTWISE_PROWL_HUNT_MODE=1` or
`--sentwise-prowl-hunt-mode` and the isolation still applies.

## Safety rules for authoring hunts

All hunts are **open-and-assert only**: open the menu, open windows, assert
presence. Even though hunt mode is isolated, do not author steps that activate
controls inside the opened windows — no Generate, Send, Approve, Deny, Save,
Delete, Search, Test Connection, Start/Pause Watching, Launch at Login,
Check for Updates, or Quit. The `forbiddenSelectors` guardrails in
`config.yml` enforce this by substring — keep them in sync with any new
interactive surfaces.

Because the macOS substring selectors can resolve short values like `Q` or
`Fo` to unsafe menu items, this config forbids `menu=` and `text=` selectors.
Menu actions must use the explicit safe AX identifiers assigned in
`MenuBarController.swift`:

| Identifier | Menu item |
|---|---|
| `id=openSetupAssistant` | Setup Assistant… |
| `id=openSettings` | Settings… |
| `id=openActivityMenu` | Activity History… |
| `id=openFollowUpComposer` | New Follow-up from Transcript… (fixture-gated) |
| `id=openReviewWindow` | Review Drafts (N)… (fixture-gated) |
| `id=openBrowseMailbox` | Browse Mailbox… (fixture-gated) |

Window presence checks use `waitForSelector` with the exact AX label each
window sets via `setAccessibilityLabel` (`label=` is a step selector; it is
not recognized inside `assert`, so rely on `waitForSelector` failing the hunt
when the window never appears):

| AX label | Window |
|---|---|
| `label="New Follow-up"` | Follow-up composer |
| `label="Review Drafts"` | Review/approval window |
| `label="Browse Mailbox"` | Mailbox browser |
| `label="Sentwise Setup"` | Onboarding / setup assistant |
| `label="Sentwise Settings"` | Settings |
| `label="Activity History"` | Activity history |

## Selector dialect (macOS target)

- `statusItem` — press the app's menu bar status item (leaves the menu open)
- `id=<axIdentifier>` — accessibility identifier when the app exposes one
- `label="…"` — exact accessibility label match (steps only, not assertions)
- `role=button[name="Save"]` — AX role + accessible name
- `menu=<title>` — disabled by this repo's guardrails; use safe `id=` selectors
- `text="…"` — disabled by this repo's guardrails

## CI (Prowl QA workflow)

`.github/workflows/prowl-qa.yml` runs the full hunt suite (`prowl ci --junit`)
against a fresh hunt-mode build on a **self-hosted macOS runner**. It installs
`prowl-tools` from npm (pinned via `PROWL_VERSION`), builds the
`prowl-macdriver` helper from the matching `prowl-tools/prowl` release tag, and
fails fast with a clear message if the runner lacks Accessibility permission.

Runner requirements (one-time, per machine):
- macOS with Xcode (the workflow builds both Sentwise and the Swift helper)
- **Accessibility** permission granted to the process hosting the runner agent
  (plus **Screen Recording** if failure screenshots are wanted)
- A logged-in GUI session — the hunts drive a real menu bar and real windows,
  so the runner cannot be a headless/SSH-only box
- Register the runner with labels `self-hosted, macOS`

The workflow is `workflow_dispatch`-only until the runner is proven; promote it
to a PR gate by uncommenting the `pull_request` trigger. Runs never execute
concurrently (a `concurrency` group serializes them — two hunts fighting over
one screen would flake).
