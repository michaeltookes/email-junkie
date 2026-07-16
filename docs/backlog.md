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

> Resolved items are recorded in [`resolved.md`](./resolved.md). Item numbers are stable IDs — they are not reused or renumbered when items are completed.

2. **First-run onboarding flow**
   Guided setup on first launch so a non-tinkering technical user can finish in a few minutes.
   *As Priya, I want a short guided setup the first time I open the app, so that I can go from install to a working assistant without reading docs.*
   - Step-by-step flow: (1) connect Gmail, (2) configure LLM provider + key, (3) choose send behavior, (4) kick off initial voice learning.
   - Each step validates before advancing (Gmail auth succeeds; key produces a successful test call).
   - Flow can be exited and resumed; completing it flips the app into "watching" state.
   - A clear privacy statement explains what stays local and what is sent to the chosen LLM.

3. **Gmail connection (OAuth)** — *PARKED (superseded by item 32 as the primary path); engine kept for a future bundled-client option*
   > **Parked 2026-07-03:** BYO OAuth proved too high-friction for non-developers, so IMAP + app password (item 32) is now the primary connection path. The OAuth engine stays in the codebase for a possible future "bundled verified client + CASA" revival. Known parked bug: loopback listener throws `NWError 22` on start. The ✅ items below are built; the ⬜ items are only relevant if OAuth is revived.

   Authenticate to Gmail with the minimum scopes needed to read inbox + Sent and create/send replies. **Distribution model (decided 2026-07-02, later superseded): bring-your-own credentials with pluggable client config. See CLAUDE.md.**
   *As Priya, I want to connect my Gmail, so that the assistant can read my mail and draft replies.*
   *As Sam, I want to supply my own Google Cloud OAuth client, so that I authorize the app under my own project with no shared-client caps or verification.*
   - ✅ PKCE desktop/loopback flow requesting only `gmail.modify` + `gmail.send`; authorization URL, code exchange, and refresh all built and unit-tested.
   - ✅ User supplies their own client ID/secret in Settings; client config is pluggable so a bundled client can be added later.
   - ✅ Tokens + client credentials stored in the macOS Keychain (item 10); access token auto-refreshes on expiry.
   - ✅ Connected-account indicator and a "disconnect" action in Settings (disconnect clears the token, keeps credentials).
   - ⬜ **Remaining:** verify the live end-to-end consent flow against a real Google client; **empirically verify refresh-token lifetime** (Testing vs Production) and document the setup so users avoid weekly re-auth; optionally show the connected account's email address; consider server-side token revocation on disconnect.

4. **Voice profile from Sent folder** — *in progress*
   Derive a reusable voice profile from Sent mail and inject it into every draft prompt.
   *As Priya, I want the assistant to study my Sent folder, so that drafts sound like me and not a generic bot.*
   - ✅ On-demand "Learn my voice" samples recent `[Gmail]/Sent Mail` messages (bodies via IMAP + `MailBodyText`, quoted-reply stripped, truncated) and derives greeting/sign-off, formality, tone, typical length, recurring phrasings via the LLM (`VoiceProfiler`, tolerant JSON parsing). Covered by pure + AppState tests.
   - ✅ Profile stored locally (`VoiceProfile.json`) and loaded on launch; `VoiceProfile.promptBlock()` renders it for prompt injection (consumed by the draft engine, item 7).
   - ✅ Human-readable summary shown in the Settings "Voice" section; Learn / Re-learn / Forget actions.
   - ✅ Learning runs off the main path with per-message progress; errors surfaced (no-samples, bad model reply, provider/mail errors).
   - ⬜ **Remaining:** live-verify against a real Sent folder + Anthropic key; wire the profile into actual draft prompts when item 7 lands; "on setup" step is part of onboarding (item 2); scheduled re-learn is item 20; empty/sparse Sent cold-start is item 25.

6. **Pluggable LLM provider layer** — *in progress*
   Provider-agnostic abstraction with adapters selected via BYO key/endpoint, designed so the local-model adapter (item 16) drops in cleanly.
   *As Sam, I want to choose which LLM provider drafts my replies, so that I'm not locked to one vendor and can keep data where I want.*
   - ✅ Common `LLMClient` interface + DTOs (`LLMRequest`/`LLMResponse`) and an injectable JSON transport; **Anthropic (Claude)** adapter implementing the Messages API. Adapter + coordinator covered by fake-transport unit tests.
   - ✅ `LLMService` resolves the selected provider + key into a client; `LLMConnectionTesting` seam so AppState is tested without the network. Provider/model and last verified model persisted in Settings (schema v4).
   - ✅ A "Test Connection" action verifies the key/model with a live call; on success the key is stored in the Keychain (item 10). "AI provider" Settings section is a working provider picker + model + API key + Test.
   - ⬜ **Remaining:** a second adapter (**OpenAI**) to exercise no-code provider switching end-to-end (the picker/seam already support it); optional custom endpoint override (BYO gateway/proxy); live-verify against a real Anthropic key. (Local-model adapter is item 16.)

7. **Draft generation engine** — *in progress*
   Produce a reply draft from the incoming message, thread context, and voice profile.
   *As Priya, I want a draft reply generated from the incoming message, its thread, and my voice profile, so that I usually only need to approve it.*
   - ✅ `DraftGenerator` builds a reply prompt from the incoming message and injects the voice profile via `VoiceProfile.promptBlock()` (neutral fallback when none); output cleaned (strips stray `Subject:` lines). Pure core + injected completion, unit-tested.
   - ✅ Provider errors/rate limits surfaced via `AppState.draftMessage(for:)` — no silent failures.
   - ✅ Draft tied to its source message (UID + UIDVALIDITY, subject, sender, `Re:` subject) for correct send later. On-demand "Draft reply" action + preview sheet in Settings.
   - ⬜ **Remaining:** incorporate full **thread/quote context** (currently the single incoming message body); capture the source **Message-ID** for `In-Reply-To`/`References` threading (needed by item 9 send); live-verify against a real inbox message; inline editing is item 19; low-confidence "needs info" handling is item 13.

9. **Send / save-as-draft (user-configurable)** — *in progress (send + save-as-draft + toggle done; live-verify remaining)*
   On approval, either send immediately or create a Gmail draft, per a setting.
   *As Priya, I want to choose whether approval sends immediately or just saves a Gmail draft, so that I can match my own comfort/trust level.*
   - ✅ **Draft-only:** a native Gmail draft is created via IMAP `APPEND` to `[Gmail]/Drafts` (`\Draft` flag), addressed to `Reply-To` when present, and threaded via `In-Reply-To`/`References` from the captured source Message-ID. RFC 822 builder (base64 body, RFC 2047 subject) + APPEND state machine covered by unit + EmbeddedChannel tests.
   - ✅ **Auto-send:** reply submitted over a hand-rolled **SMTP** client on NIO (implicit TLS on 465, `AUTH LOGIN`, `MAIL FROM`/`RCPT TO`/`DATA` with dot-stuffing). Reuses the same RFC 822 builder for correct subject/threading; SMTP host derived from the IMAP host (`imap.` → `smtp.`). Response decoder + send state machine covered by EmbeddedChannel tests.
   - ✅ **Toggle:** `SendBehavior` setting (save-as-draft vs auto-send, schema v5) with a "On approve" picker in Settings; `approveGeneratedDraft()` dispatches to send or save. The draft preview's action reflects the choice ("Send now" vs "Save to Drafts").
   - ✅ The approval UI indicates what "Approve" will do — the Review Drafts window (item 8) shows "Approve will send/save" and labels the button accordingly; the Settings preview also reflects it.
   - ⬜ Live-verify a real send + a real draft appear and thread correctly in Gmail (against a real account + app password).

11. **Distribution: signed DMG + Sparkle + Homebrew cask**
    Reuse the Prompter shipping pipeline.
    *As Priya, I want to install via DMG or Homebrew and get automatic updates, so that setup and upkeep are frictionless and not scary.*
    - Signed, notarized DMG installs without Gatekeeper "unidentified developer" warnings.
    - Homebrew cask available in a tap.
    - Sparkle auto-update works against a published appcast.
    - Pipeline mirrors the Prompter release workflow.

12. **Stale-thread / conflict detection before send**
    Re-check thread state at approval time so an approved draft is never sent into a changed conversation.
    *As Priya, I want the app to notice if a thread changed before it sends my approved draft, so that I never send a duplicate or out-of-context reply.*
    - Before sending/saving (item 9), the source thread is re-fetched and compared to when the draft was generated.
    - If a new reply arrived, the user already replied, or the message was archived/deleted, the send is blocked and the user is warned with options (regenerate, send anyway, discard).
    - Especially enforced in auto-send mode, where a stale send is silent and embarrassing.
    - Detection logic is covered by tests against representative thread-change cases.

13. **Low-confidence / "needs info" draft handling**
    When the model can't draft well without facts only the user has, flag it instead of hallucinating.
    *As Priya, I want the app to tell me when it can't confidently draft a reply, so that I trust the drafts it does produce.*
    - The engine detects low-confidence or missing-information cases (e.g. the reply requires data not in the thread).
    - Instead of a fabricated reply, the user is shown a clear "needs your input" state with what's missing.
    - No auto-send ever fires on a flagged draft.
    - Flagged items appear distinctly in the approval UI and activity history (item 21).

## Medium Priority

16. **Local model support**
    A local-model adapter for fully-offline drafting.
    *As Sam, I want to run drafting against a local model, so that no email content ever leaves my machine.*
    - Local-model adapter (e.g. Ollama) implements the same provider interface as cloud adapters (item 6).
    - Selectable in Settings with no behavioral difference elsewhere.
    - Documented setup for the local runtime.

17. **Reply-worthiness filtering**
    Decide which incoming emails get a draft.
    *As Priya, I want newsletters, no-reply, and bulk mail filtered out, so that I'm not flooded with pointless drafts and don't burn LLM cost.*
    - Heuristics skip obvious non-replyable mail (no-reply senders, bulk/list headers, automated notifications, calendar invites).
    - Skipped reasons visible in the activity log (item 21).
    - User can override and force a draft for a skipped message.

18. **Sender allowlist / blocklist & rules**
    Control which senders are drafted.
    *As Priya, I want to choose which senders are always or never drafted, so that I control the watcher's scope.*
    - Settings supports allowlist / blocklist by sender address or domain.
    - Rules take effect on the next poll without restart.
    - Rules persisted locally.

19. **Inline draft editing before send**
    Tweak a draft in the approval UI before approving.
    *As Priya, I want to tweak a draft before approving, so that I can fix small things without rejecting the whole reply.*
    - Approval UI allows inline editing of the draft body.
    - Edited content is what gets sent or saved.
    - Edits can optionally be captured as a signal for future voice tuning.

20. **Voice profile refresh / re-learn**
    Keep the profile current.
    *As Priya, I want to re-learn my voice on demand or on a schedule, so that drafts keep up as my style changes.*
    - A "re-learn" action re-samples Sent and updates the profile.
    - Optional scheduled refresh interval in Settings.
    - Previous profile replaced atomically; a summary of changes shown.

21. **Activity history view**
    See what the assistant has done.
    *As Priya, I want to see drafted/approved/denied/sent/skipped events, so that I can trust it and debug surprises.*
    - History lists events with timestamps and reasons.
    - Entries link back to the relevant message where possible.
    - History stored locally and can be cleared.

22. **Cost & rate guardrails for cloud LLMs**
    Prevent surprise bills.
    *As Priya, I want usage limits and cost visibility for cloud providers, so that BYO-key drafting never surprises me.*
    - Token/usage tracked per run and per day.
    - Configurable caps pause drafting when exceeded, with a clear notification.
    - Estimated cost visible in the activity log/settings.

23. **Send safety net (undo / cancel window)**
    A grace period after approval so a bad auto-send can be stopped.
    *As Priya, I want a few seconds to cancel after I approve, so that one mistaken approval doesn't go out.*
    - In auto-send mode, approval starts a short, configurable countdown before the actual send.
    - The user can cancel during the window; cancel returns the draft to pending.
    - Disabling the window is possible for users who want instant send.
    - Pairs with item 12 — stale-thread checks run at the end of the window, immediately before send.

24. **Email signature handling**
    Respect the user's signature so drafts look right.
    *As Priya, I want drafts to use my normal signature correctly, so that replies don't drop it or double it up.*
    - Signature policy is configurable (use Gmail's, a custom one, or none).
    - Generated drafts neither omit an expected signature nor duplicate one already present.
    - Quoted history below the signature is handled correctly.

25. **Voice-profile cold start**
    Graceful behavior when there's little or no Sent history.
    *As a new user, I want sensible drafts even before the app has learned much, so that an empty Sent folder doesn't break onboarding.*
    - Detects sparse/empty Sent history and falls back to a sensible neutral profile.
    - Communicates that voice will improve as more mail is sent and on re-learn (item 20).
    - Never blocks onboarding (item 2) on insufficient history.

26. **Quiet hours / notification batching**
    Don't interrupt at night; optionally batch drafts.
    *As Priya, I want quiet hours and batched notifications, so that the assistant doesn't ping me at 2am or one message at a time.*
    - Configurable quiet-hours window during which notifications are suppressed and queued.
    - Optional batching so multiple ready drafts surface together rather than individually.
    - Queued drafts are delivered when quiet hours end.

27. **Resilience: offline queue + retry**
    Handle network/API/token failures as a system, not just per draft.
    *As Priya, I want the app to recover from dropped connections and transient API errors, so that it keeps working without my intervention.*
    - Operations (fetch, draft, send) retry with backoff on transient failures.
    - Work is queued while offline and resumes on reconnect.
    - Token-expiry and auth failures are recovered or surfaced clearly (ties to item 3).
    - No duplicate sends result from retries.

28. **Accessibility of the approval UI**
    Make the core loop usable for everyone.
    *As a keyboard/VoiceOver user, I want to review and approve drafts without a mouse, so that the app is usable for me.*
    - Popover and approval UI are fully VoiceOver-labeled and keyboard-navigable.
    - Approve/deny/edit actions have keyboard shortcuts.
    - Respects system Dynamic Type, contrast, and reduce-motion settings.

29. **CD release automation**
    Automate the item 11 release pipeline via GitHub Actions on tagged releases.
    *As a maintainer, I want tagged releases built and shipped automatically, so that cutting a release is one push, not a manual checklist.*
    - On a version tag, a workflow builds, signs, and notarizes the app and produces the DMG.
    - It publishes a GitHub release, updates the Sparkle appcast, and bumps the Homebrew cask.
    - Signing secrets are handled securely via encrypted CI secrets.
    - Mirrors the existing Prompter release workflow / `release-prep` skill steps.

## Low Priority

30. **Slack approval channel**
    Optional Slack integration for users who live in Slack.
    *As a Slack-native user, I want drafts posted to Slack with approve/deny actions, so that approval fits my existing workflow.*
    - Opt-in, configured in Settings.
    - Posts drafts to a channel/DM with approve/deny actions.
    - Approve/deny routes through the same send/draft path as the native UX.

31. **Outlook / Microsoft 365 support**
    Add an Outlook/M365 provider behind the email-provider abstraction.
    *As an Outlook user, I want to connect my M365 mailbox, so that I can use email-junkie without Gmail.*
    - Graph API + OAuth provider implementing the shared email-provider interface.
    - Feature parity with Gmail for read/draft/send.

32. **IMAP/SMTP connection (app password)** — *PRIMARY connection path*
    IMAP + Google app password is the primary way users connect (decided 2026-07-03, superseding OAuth item 3). Provider-agnostic, works for Gmail/Outlook/any IMAP host. Built on SwiftNIO (`swift-nio-imap`) in `Packages/EmailJunkieMail`.
    *As anyone, I want to connect by pasting my email + an app password, so that I skip Google Cloud setup entirely.*
    - ✅ `MailProvider` protocol + `IMAPMailProvider` (TLS connect + IMAP LOGIN/LOGOUT); "Test Connection" wired into Settings; app password stored in Keychain. **Live-verified against real Gmail 2026-07-04.**
    - ✅ Recent-message fetch (LOGIN → SELECT → FETCH UID+ENVELOPE → LOGOUT), newest first; sender/subject/date parsed; "Preview inbox" action in Settings. State machine + envelope parsing covered by EmbeddedChannel tests.
    - ✅ Body-text fetch (`UID FETCH BODY.PEEK[TEXT]`, streaming assembly over NIO, no `\Seen` flag set) + `MailBodyText` readable-text reduction (multipart, quoted-printable/base64, HTML-strip fallback). "View body" preview sheet in Settings. Covered by EmbeddedChannel + pure unit tests.
    - ⬜ **Remaining:** live-verify fetch + body against real Gmail (incl. `[Gmail]/Sent Mail`); hand-rolled **SMTP send** over NIO; efficient `BODYSTRUCTURE`-guided fetch of just the `text/plain` part (avoids downloading attachments; also fixes single-part transfer-encoding decoding); handle missing provider-native features (push, labels) gracefully.

33. **Multiple-account support**
    Watch more than one mailbox.
    *As Priya, I want to connect multiple mailboxes, so that work and personal email are both handled.*
    - Multiple accounts, each with its own voice profile and settings.
    - Clear per-account attribution in notifications and history.

34. **Per-recipient / per-context voice profiles**
    Distinct voice tuning per relationship.
    *As Priya, I want different tone for clients vs teammates, so that drafts fit each relationship.*
    - Optional per-recipient or per-context voice variants.
    - Falls back to the base profile when no variant applies.

35. **Opt-in anonymous telemetry**
    Privacy-respecting, off-by-default metrics.
    *As a maintainer, I want opt-in usage signal, so that I can prioritize development without compromising privacy.*
    - Off by default, fully disclosed, opt-in only.
    - No email content ever included.

36. **Diagnostics / log export**
    Developer-facing logs for OSS bug reports.
    *As Sam, I want to export diagnostic logs, so that I can file a useful bug report without leaking email content.*
    - A "export diagnostics" action produces redacted logs (no message bodies/PII by default).
    - Distinct from the user-facing activity history (item 21).
    - Log verbosity is configurable.

37. **Gmail push (watch API) real-time option**
    True real-time inbox updates as an upgrade over polling.
    *As Priya, I want near-instant drafts when mail arrives, so that I'm not waiting on a poll interval.*
    - Optional Gmail `watch` (Pub/Sub) push path as an alternative to the item 5 poller.
    - Documented infrastructure tradeoffs vs the local-first polling default.
    - Falls back to polling when push isn't available.

38. **CI hardening (required checks + caching)**
    Follow-ups from the initial CI pipeline (item 15).
    *As a maintainer, I want CI enforced and fast, so that broken code can't merge and runs stay cheap.*
    - Enable branch protection on `main` requiring the CI check to pass before merge.
    - Cache SwiftPM/Xcode build dependencies to speed up runs.
