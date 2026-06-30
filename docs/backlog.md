# Backlog

Prioritized list of planned features, improvements, and technical debt for **email-junkie** — a native, local-first, open-source macOS menu-bar email assistant that learns your voice from your Sent mail, watches your inbox, drafts replies with a pluggable LLM, and surfaces them for one-tap approval.

**v1 design decisions (locked):**
- **Platform:** native macOS menu-bar app (Swift), following the Prompter distribution pattern (DMG + Homebrew cask + Sparkle auto-update).
- **Approval channel:** native macOS notification first. (Slack is a future item.)
- **Email provider:** Gmail first. (Outlook/M365 and IMAP/SMTP are future items.)
- **Send behavior:** user-configurable — auto-send on approve *or* save-as-draft.
- **LLM access:** pluggable BYO-any-provider **and** a local-model option.
- **Ethos:** local-first, private, BYO-key, no subscription. Data stays on the user's machine except the LLM call (which the user controls).

**Personas referenced in stories below:**
- **Priya — busy technical professional (primary).** A Solutions Architect. Comfortable installing a signed Mac app and pasting an API key, but does *not* want to run servers or babysit a CLI. Lives in email; wants drafts waiting so she can triage in seconds. Cares about privacy and control.
- **Sam — self-hoster / privacy maximalist (secondary).** Wants everything local, will run a local model, may bring their own Google Cloud credentials. Values openness and "no data leaves my machine."

> **Item format:** every item has a bold title, a one-line summary, a user story (*As a … I want … so that …*), and acceptance criteria. See `CLAUDE.md` for backlog conventions.

---

## High Priority

1. **macOS menu-bar app shell**
   Swift menu-bar (`NSStatusItem`) app with a popover UI, background-agent lifecycle, and a Settings window — the foundation every other feature hangs off of. Model it on the Prompter app structure.
   *As Priya, I want email-junkie to live quietly in my menu bar, so that it runs in the background without cluttering my Dock or stealing focus.*
   - App launches as a menu-bar item with no Dock icon by default.
   - Clicking the icon opens a popover showing status (watching / idle / drafts pending) and a path to Settings.
   - App can be set to launch at login.
   - Quitting from the popover fully stops background watching.

2. **First-run onboarding flow**
   Guided setup on first launch so a non-tinkering technical user can finish in a few minutes.
   *As Priya, I want a short guided setup the first time I open the app, so that I can go from install to a working assistant without reading docs.*
   - Step-by-step flow: (1) connect Gmail, (2) configure LLM provider + key, (3) choose send behavior, (4) kick off initial voice learning.
   - Each step validates before advancing (Gmail auth succeeds; key produces a successful test call).
   - Flow can be exited and resumed; completing it flips the app into "watching" state.
   - A clear privacy statement explains what stays local and what is sent to the chosen LLM.

3. **Gmail connection (OAuth)**
   Authenticate to Gmail with the minimum scopes needed to read inbox + Sent and create/send replies.
   *As Priya, I want to connect my Gmail with one click, so that the assistant can read my mail and draft replies.*
   *As Sam, I want to supply my own Google Cloud OAuth client, so that I can authorize the app even on a locked-down Workspace.*
   - OAuth requests only required scopes (`gmail.readonly` + `gmail.modify`/`gmail.send`).
   - Tokens stored in the macOS Keychain (see item 10); refresh handled automatically.
   - Connected-account indicator and a "disconnect" action in Settings; revoking stops all reads/writes immediately.
   - Settings allows entering a custom OAuth client ID/secret; docs explain the Google Cloud "Testing mode" path (≤100 users, skips CASA) and its implications.
   - App behaves identically with the bundled client or a BYO client.

4. **Voice profile from Sent folder**
   Derive a reusable voice profile from Sent mail and inject it into every draft prompt.
   *As Priya, I want the assistant to study my Sent folder, so that drafts sound like me and not a generic bot.*
   - On setup (and on demand), samples recent Sent messages to derive tone, greeting/sign-off, formality, typical length, recurring phrasings.
   - Profile stored locally and injected into every draft-generation prompt.
   - User can view a human-readable summary of what was learned.
   - Learning runs without blocking the UI and reports progress.

5. **Inbox watcher**
   Poll the inbox on a timer while the Mac is awake and enqueue replyable messages for drafting.
   *As Priya, I want the app to notice new emails that need a reply while my Mac is on, so that drafts are ready when I check.*
   - Inbox polled on a configurable interval while the Mac is awake; resumes cleanly on wake.
   - Newly-arrived, plausibly-replyable messages are enqueued for drafting.
   - Already-processed messages are tracked and never drafted twice.
   - No claim of 24/7 coverage; sleep/wake behavior is well-defined.

6. **Pluggable LLM provider layer**
   Provider-agnostic abstraction with adapters selected via BYO key/endpoint, designed so the local-model adapter (item 12) drops in cleanly.
   *As Sam, I want to choose which LLM provider drafts my replies, so that I'm not locked to one vendor and can keep data where I want.*
   - Common interface with adapters for cloud providers (Claude, OpenAI, etc.) via BYO key/endpoint.
   - Switching providers in Settings takes effect immediately with no code changes.
   - A "test connection" action verifies the key/endpoint.
   - Keys stored in Keychain (item 10).

7. **Draft generation engine**
   Produce a reply draft from the incoming message, thread context, and voice profile.
   *As Priya, I want a draft reply generated from the incoming message, its thread, and my voice profile, so that I usually only need to approve it.*
   - Drafts incorporate thread/quote context and the voice profile.
   - Provider errors, timeouts, and rate limits are handled gracefully and surfaced (no silent failures).
   - Each draft is associated with its source message and thread for correct sending later.

8. **Native macOS notification approval UX**
   Surface a ready draft via native notification + preview, with approve/deny.
   *As Priya, I want a native notification when a draft is ready, so that I can review and act without hunting through an app.*
   - Native macOS notification fires when a draft is ready.
   - A popover/preview shows the incoming message and proposed reply side by side.
   - Approve and Deny actions available; Deny discards.
   - Multiple pending drafts are queued and individually actionable.

9. **Send / save-as-draft (user-configurable)**
   On approval, either send immediately or create a Gmail draft, per a setting.
   *As Priya, I want to choose whether approval sends immediately or just saves a Gmail draft, so that I can match my own comfort/trust level.*
   - Setting toggles "auto-send on approve" vs "save as draft."
   - Auto-send: reply sent via Gmail, correctly threaded (In-Reply-To/References, recipients, subject).
   - Draft-only: a native Gmail draft is created in the right thread; nothing is sent.
   - The approval UI clearly indicates what "Approve" will do in the current mode.

10. **Secure local storage**
    Keychain for secrets; local-only storage for profile and state.
    *As Sam, I want my tokens and keys stored securely and my email kept local, so that I can trust the app with my inbox.*
    - OAuth tokens and LLM API keys stored in the macOS Keychain, never plaintext.
    - Voice profile and app state stored locally; nothing transmitted except the user-controlled LLM call.
    - Accurate privacy statement shown in onboarding and Settings.
    - Disconnecting an account or quitting removes/disables access cleanly.

11. **Distribution: signed DMG + Sparkle + Homebrew cask**
    Reuse the Prompter shipping pipeline.
    *As Priya, I want to install via DMG or Homebrew and get automatic updates, so that setup and upkeep are frictionless and not scary.*
    - Signed, notarized DMG installs without Gatekeeper "unidentified developer" warnings.
    - Homebrew cask available in a tap.
    - Sparkle auto-update works against a published appcast.
    - Pipeline mirrors the Prompter release workflow.

## Medium Priority

12. **Local model support**
    A local-model adapter for fully-offline drafting.
    *As Sam, I want to run drafting against a local model, so that no email content ever leaves my machine.*
    - Local-model adapter (e.g. Ollama) implements the same provider interface as cloud adapters.
    - Selectable in Settings with no behavioral difference elsewhere.
    - Documented setup for the local runtime.

13. **Reply-worthiness filtering**
    Decide which incoming emails get a draft.
    *As Priya, I want newsletters, no-reply, and bulk mail filtered out, so that I'm not flooded with pointless drafts and don't burn LLM cost.*
    - Heuristics skip obvious non-replyable mail (no-reply senders, bulk/list headers, automated notifications, calendar invites).
    - Skipped reasons visible in the activity log (item 17).
    - User can override and force a draft for a skipped message.

14. **Sender allowlist / blocklist & rules**
    Control which senders are drafted.
    *As Priya, I want to choose which senders are always or never drafted, so that I control the watcher's scope.*
    - Settings supports allowlist / blocklist by sender address or domain.
    - Rules take effect on the next poll without restart.
    - Rules persisted locally.

15. **Inline draft editing before send**
    Tweak a draft in the approval UI before approving.
    *As Priya, I want to tweak a draft before approving, so that I can fix small things without rejecting the whole reply.*
    - Approval UI allows inline editing of the draft body.
    - Edited content is what gets sent or saved.
    - Edits can optionally be captured as a signal for future voice tuning.

16. **Voice profile refresh / re-learn**
    Keep the profile current.
    *As Priya, I want to re-learn my voice on demand or on a schedule, so that drafts keep up as my style changes.*
    - A "re-learn" action re-samples Sent and updates the profile.
    - Optional scheduled refresh interval in Settings.
    - Previous profile replaced atomically; a summary of changes shown.

17. **Activity history view**
    See what the assistant has done.
    *As Priya, I want to see drafted/approved/denied/sent/skipped events, so that I can trust it and debug surprises.*
    - History lists events with timestamps and reasons.
    - Entries link back to the relevant message where possible.
    - History stored locally and can be cleared.

18. **Cost & rate guardrails for cloud LLMs**
    Prevent surprise bills.
    *As Priya, I want usage limits and cost visibility for cloud providers, so that BYO-key drafting never surprises me.*
    - Token/usage tracked per run and per day.
    - Configurable caps pause drafting when exceeded, with a clear notification.
    - Estimated cost visible in the activity log/settings.

## Low Priority

19. **Slack approval channel**
    Optional Slack integration for users who live in Slack.
    *As a Slack-native user, I want drafts posted to Slack with approve/deny actions, so that approval fits my existing workflow.*
    - Opt-in, configured in Settings.
    - Posts drafts to a channel/DM with approve/deny actions.
    - Approve/deny routes through the same send/draft path as the native UX.

20. **Outlook / Microsoft 365 support**
    Add an Outlook/M365 provider behind the email-provider abstraction.
    *As an Outlook user, I want to connect my M365 mailbox, so that I can use email-junkie without Gmail.*
    - Graph API + OAuth provider implementing the shared email-provider interface.
    - Feature parity with Gmail for read/draft/send.

21. **Generic IMAP/SMTP support**
    Provider-agnostic backend for self-hosters.
    *As Sam, I want to connect any IMAP/SMTP mailbox, so that I'm not limited to Gmail or Outlook.*
    - IMAP read + SMTP send behind the shared provider interface.
    - Graceful handling of missing provider-native features (push, labels).

22. **Multiple-account support**
    Watch more than one mailbox.
    *As Priya, I want to connect multiple mailboxes, so that work and personal email are both handled.*
    - Multiple accounts, each with its own voice profile and settings.
    - Clear per-account attribution in notifications and history.

23. **Per-recipient / per-context voice profiles**
    Distinct voice tuning per relationship.
    *As Priya, I want different tone for clients vs teammates, so that drafts fit each relationship.*
    - Optional per-recipient or per-context voice variants.
    - Falls back to the base profile when no variant applies.

24. **Opt-in anonymous telemetry**
    Privacy-respecting, off-by-default metrics.
    *As a maintainer, I want opt-in usage signal, so that I can prioritize development without compromising privacy.*
    - Off by default, fully disclosed, opt-in only.
    - No email content ever included.

## Completed
