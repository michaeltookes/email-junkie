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

From this directory's repo root:

```bash
xcodebuild build -project Sentwise/Sentwise.xcodeproj -scheme Sentwise -configuration Debug -derivedDataPath .prowl/DerivedData CODE_SIGNING_ALLOWED=NO
prowl list
prowl run menu-smoke
prowl run settings-window
prowl run activity-history
```

Each run launches the Sentwise app at
`.prowl/DerivedData/Build/Products/Debug/Sentwise.app`, drives it, and quits it
afterward. Artifacts land in `.prowl/runs/` (gitignored).

## Safety

Launching Sentwise uses your real settings/Keychain, so it may auto-connect to
the live mailbox. All hunts here are **read-only** (open menu, open safe
windows, assert visible) — keep them that way until there's a test-account
setup. Do not author steps that touch drafts, sending, live watching, mailbox
browsing/cleanup, follow-up composition, login items, Sparkle update checks, or
app quit. Keep the `forbiddenSelectors` guardrails in sync with those surfaces.
Because the macOS substring selectors can resolve short values like `Q` or `Fo`
to unsafe menu items, this config forbids `menu=` and `text=` selectors. Menu
actions must use explicit safe AX identifiers (`id=openSettings`,
`id=openActivityMenu`, `id=openSetupAssistant`), and window checks should use
exact `label=` selectors.

## Selector dialect (macOS target)

- `statusItem` — press the app's menu bar status item (leaves the menu open)
- `menu=<title>` — disabled by this repo's guardrails; use safe `id=` selectors
- `id=<axIdentifier>` — accessibility identifier when the app exposes one
- `role=button[name="Save"]` — AX role + accessible name
- `text="…"` — disabled by this repo's guardrails; use exact `label=` where possible
- `label="…"` — exact accessibility label match
