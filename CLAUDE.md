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

### Resolved: Gmail OAuth distribution model (2026-07-02)
**Bring-your-own credentials is the v1 primary path, with the OAuth client config built pluggable** so a bundled client can be added later. Each user supplies their own Google Cloud OAuth client. This avoids Google's verification + annual CASA assessment (required to distribute a shared client for restricted Gmail scopes), the 100-user Testing-mode cap, and the ~7-day Testing-mode refresh-token expiry — and it fits the technical/open-source audience while keeping the maintainer free of cost and inbox-data custody. When building item 3, **empirically verify refresh-token lifetime** (Testing vs Production) with a real account so onboarding docs are accurate. Bundled-client and CASA paths are deferred, not chosen.

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
