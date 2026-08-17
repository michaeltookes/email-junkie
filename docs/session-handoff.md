# Session handoff — where we left off (2026-08-17)

A point-in-time status note for resuming work after the local repo rename
(`~/Developer/email-junkie` → `~/Developer/sentwise`, the final step of the
Sentwise rename). Delete or update this file freely once its contents are stale.

## Product state

- **Shipped:** Sentwise v0.1.1 (signed, notarized, Sparkle-enabled) via the
  manual pipeline. v0.1.0 had a launch crash (rpath), fixed in v0.1.1.
- **Rename fully complete:** product, bundle id, GitHub repo, domains
  (sentwise.ai canonical), and now the local directory. Session memory was
  migrated to the new project key.
- **QA layers in place:** 914-test unit suite, CI (lint + both test halves),
  and 7 Prowl accessibility hunts covering every product window (all green;
  the prowl macOS-target instance-reuse race was found here and fixed upstream).

## Active item: 29 — CD release automation (High)

Everything is built on `main` (`.github/workflows/release.yml`,
`docs/ci-release.md`, hardened `release.sh` with launch smoke test). Closing
sequence:

1. **Blocked on the maintainer:** set the five sensitive GitHub secrets per
   `docs/ci-release.md` — `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`,
   `NOTARY_APP_SPECIFIC_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`, `TAP_PUSH_TOKEN`.
   (`APPLE_ID` and `APPLE_TEAM_ID` are already set.)
2. Optionally land **item 64** first (onboarding friction fix — small,
   builder-suited, needs a branch name) so v0.1.2 carries user-facing value.
3. Tag `v0.1.2` → workflow must run green end to end (a `workflow_dispatch`
   unsigned dry-run mode exists for rehearsal).
4. Verify **Sparkle auto-update** on the maintainer's installed v0.1.1
   (discover → download → signature-verify → install). That criterion has been
   carried since item 11; when it passes, item 29 closes.

## Queued after item 29

- **Item 57 discussion** (landing page; gates monetization items 56/59) —
  a conversation, not build work; own repo when it starts.
- **Item 65** — native macOS Settings window (larger UI piece).
- Dogfooding item 51 on real calls feeds items 52 (calendar), 58 (harness),
  62 (deal memory).

## Working conventions (recent changes)

- **No AI co-author trailers on any commit** (global, 2026-08-16; kickoff
  skill updated, memory saved). Include the rule in builder briefs.
- Branch-first always; docs-only commits may go straight to `main`.
- Builder briefs must mandate foreground `xcodebuild test`; a builder that
  reports "waiting on a build" is deadlocked — nudge it to a foreground re-run.
