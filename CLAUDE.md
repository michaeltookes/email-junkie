# CLAUDE.md

Guidance for agents working in the **email-junkie** repository.

## What this is

email-junkie is a **native, local-first, open-source macOS menu-bar email assistant**. It learns the user's voice from their Sent mail, watches the inbox, drafts replies with a pluggable LLM, and surfaces those drafts for one-tap approval via a native macOS notification.

It is a **Prompter-family product** — a native Mac app for individual knowledge-worker productivity — **not** part of the Prowl Tools (CLI-first developer SDLC) suite. Keep that identity clear: this is a private, on-device GUI app for busy professionals, not developer tooling.

### v1 design decisions (locked)
- **Platform:** native macOS menu-bar app (Swift), shipped via the Prompter pattern — signed/notarized DMG + Homebrew cask + Sparkle auto-update.
- **Approval channel:** native macOS notification first. Slack is a future item.
- **Email provider:** Gmail first. Outlook/M365 and IMAP/SMTP are future items.
- **Send behavior:** user-configurable — auto-send on approve *or* save-as-draft.
- **LLM access:** pluggable BYO-any-provider, plus a local-model option (e.g. Ollama).
- **Ethos:** local-first, private, BYO-key, no subscription. Nothing leaves the machine except the user-controlled LLM call. Secrets live in the macOS Keychain.

### Email connection method (updated 2026-07-03): IMAP + app password
**The primary connection path is IMAP + a Google app password**, implemented with SwiftNIO (`swift-nio-imap`) in the local `Packages/EmailJunkieMail` package. Users paste their email + a 16-character app password (2FA required) — no Google Cloud console, no client ID/secret, no verification/CASA.

This **superseded an earlier BYO-OAuth decision** (2026-07-02): we built the full Google OAuth flow (item 3) but live testing showed BYO OAuth is far too much friction for non-developers (create a Cloud project, enable APIs, configure a consent screen, make a Desktop client). The OAuth engine (`GmailAuthCoordinator`, `OAuthTokenService`, `LoopbackRedirectListener`, etc.) **remains in the codebase, parked** — it's the future "bundled verified client + CASA" option if the product ever targets the non-technical mass market. Known parked bug: the OAuth loopback listener throws `NWError 22` on start; unfixed because that path isn't primary.

We first tried **MailCore2** for IMAP but its SPM/arm64 distribution is abandoned (2020/2022 binaries), so we use Apple's `swift-nio-imap` instead. See [[oauth-byo-credentials-decision]] memory.

## Backlog Management

Active items live in `docs/backlog.md`; completed items live in `docs/resolved.md`.

**Conventions** (follow these exactly):
- Items use priority tiers (**High / Medium / Low**). New items are numbered sequentially after the highest existing number.
- **Item numbers are stable IDs.** They are not reused or renumbered when an item is completed — this keeps cross-references (e.g. "see item 10") and git history (commits that reference "item N") valid. A resolved tier may therefore start at a number other than 1.
- Each item has: a **bold title**, a one-line summary, a **user story** in *As a … I want … so that …* form, and **acceptance criteria** as a bullet list. We embed user stories directly in backlog items — do **not** create a separate user-stories file.
- Keep descriptions concise but complete enough for any agent to act without re-deriving intent.

When you **complete** work that corresponds to a backlog item, follow the `/update-backlog` skill:
- Move the item to `docs/resolved.md` using the strikethrough format: `### ~~N: Title~~`, with a `**Resolved**: YYYY-MM-DD (commit HASH or branch NAME)` line and a synthesized description of what was actually delivered.
- Remove the item's block from `docs/backlog.md`. Do **not** renumber the remaining items.

When you **discover** new bugs, tech debt, or feature opportunities:
- Read the backlog file and add the item to the appropriate priority tier (default **Medium** if unsure).
- Match the existing format: numbered, bold title, one-line summary, user story, acceptance criteria.

The `/update-backlog` skill automates matching commits to items — keep the file's format stable so it keeps working.

## Workflow rules

- **Never commit directly to `main`.** Branch first; ask for a branch name if one isn't given.
- **Never open pull requests** unless explicitly asked — commit and push to the branch only.
- Commit and push only when the user asks.
