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

### Open decision to resolve before building Gmail auth (item 3)
Distributing one shared Google OAuth client for a public build means either staying under Google's 100-user "Testing mode" cap or paying for the annual CASA security assessment to reach Production. This affects how broadly the app can be distributed without spend. Decide before implementing the bundled-client path.

## Backlog Management

This project's backlog is tracked at: `docs/backlog.md`

**Conventions** (follow these exactly):
- Items use priority tiers (**High / Medium / Low**) with **sequential numbering across all tiers**.
- Each item has: a **bold title**, a one-line summary, a **user story** in *As a … I want … so that …* form, and **acceptance criteria** as a bullet list. We embed user stories directly in backlog items — do **not** create a separate user-stories file.
- Keep descriptions concise but complete enough for any agent to act without re-deriving intent.

When you **complete** work that corresponds to a backlog item:
- Read the backlog file and find the matching item.
- Move it to the `## Completed` section with the date: `(completed: YYYY-MM-DD)`.
- Use a bullet (remove the number prefix) and re-number remaining items to stay sequential.

When you **discover** new bugs, tech debt, or feature opportunities:
- Read the backlog file and add the item to the appropriate priority tier (default **Medium** if unsure).
- Match the existing format: numbered, bold title, one-line summary, user story, acceptance criteria.

The `/update-backlog` skill automates matching commits to items — keep the file's format stable so it keeps working.

## Workflow rules

- **Never commit directly to `main`.** Branch first; ask for a branch name if one isn't given.
- **Never open pull requests** unless explicitly asked — commit and push to the branch only.
- Commit and push only when the user asks.
