# Backlog

Prioritized list of planned features, improvements, and technical debt for **sentwise** — a native, local-first macOS assistant that learns your voice from your Sent mail and drafts email on your behalf for one-tap approval. Its **flagship workflow (2026-08-12 pivot)** is the **post-call follow-up**: when a call ends, ingest the transcript and draft the next-steps email in the user's voice. Inbox reply drafting remains, as one workflow among several.

**Product direction (updated 2026-08-12):**
- **Flagship workflow:** transcript in → next-steps follow-up email out, in the user's voice (items 51–55). The existing drafting → approval → send plumbing is reused; transcript acquisition is the new subsystem, phased: file/paste ingestion first (51), calendar awareness (52), platform APIs (53), native no-bot capture last (54).
- **Primary commercial ICP:** Account Executives / salespeople in high-velocity roles (see **Marcus** persona). Priya remains the persona for the inbox-reply workflow.
- **No bot, no storage, no training:** calls are never joined by a bot; audio and (future) capture/transcription stay on-device; call content is never stored on our servers or used as training data. Drafting inference runs through a **stateless zero-retention proxy** by default (see Monetization), or entirely under the user's control via the BYO-key / local-model escape hatch. **Competitive note (2026-08-12):** Fathom ships bot-free desktop capture and Granola always has — and cloud notetakers store calls indefinitely and train on (de-identified) customer data per their own policies. The durable differentiators are (a) privacy that's minimized *and* guaranteed — nothing stored, nothing trained on, plus a BYO/local tier where we're not in the loop at all — and (b) the workflow's back half: a **send-ready email in the user's learned voice, sent from their own mailbox**, not a summary stranded in a notetaker app.
- **Non-goals (2026-08-13, from the momentum.io teardown):** manager/exec-facing surfaces — coaching scorecards, team dashboards, CRO briefings, churn signals, call-clip libraries. Momentum.io (now Salesforce) owns that org-facing lane; our value flows to the **individual rep**, and the org benefits only indirectly via CRM logging (item 55). Agents should not drift features toward the manager persona.
- **Monetization (updated 2026-08-12, second revision — supersedes both "no subscription" and BYO-key-as-default):** subscription with **managed inference bundled** — the user never touches an API key or provider billing. Unit economics support it: a follow-up costs single-digit cents, so ~175 follow-ups/month ≈ $2–8 against a ~$15–20/mo subscription. Open core / paid binary — source stays public, signed auto-updating binaries are licensed; the license is an **account/sign-in** (needed for inference metering anyway). Trial → Individual → Team with CRM logging (items 55–56); Enterprise explicitly parked. **BYO-key / local-model remains as the power/privacy option** (items 58–59) — the plumbing exists, it serves Sam and heavy users, and it's the tier where call content never touches any server.

**v1 design decisions:**
- **Platform:** native macOS menu-bar app (Swift), following the Prompter distribution pattern (DMG + Homebrew cask + Sparkle auto-update). **Affirmed over an Electron rewrite 2026-08-12** — validate on macOS first (the ICP skews Mac); measure Windows demand via a landing-page waitlist (item 57) and revisit Tauri/Electron only if it fills.
- **Approval channel:** native macOS notification first. (Slack is a future item.)
- **Email provider:** Gmail first. (Outlook/M365 and IMAP/SMTP are future items.)
- **Send behavior:** user-configurable — auto-send on approve *or* save-as-draft.
- **LLM access:** pluggable provider architecture — **managed inference is the default** (bundled, no keys; item 56); BYO-any-provider and a local-model option remain as the power/privacy path (item 59).
- **Ethos:** local-first, private. Mail data, voice profile, and (future) call audio stay on the user's machine; drafting inference leaves only as a stateless, zero-retention call — via the managed proxy by default, or the user's own key / local model. *(The original "no subscription" and BYO-key-by-default clauses were superseded 2026-08-12 — see Monetization above.)*

**Personas referenced in stories below:**
- **Marcus — Account Executive, high-velocity sales (primary commercial ICP).** Runs 4–8 calls a day on Zoom/Meet/Teams from a company MacBook. Post-call admin — follow-up emails, CRM logging — eats 30+ minutes daily. Expenses $15–20/mo tools without blinking; his manager cares that activity lands in the CRM. May already use a notetaker (Fathom/Granola/Otter) — those transcripts are an ingestion source, not competition.
- **Priya — busy technical professional.** A Solutions Architect. Comfortable installing a signed Mac app and pasting an API key, but does *not* want to run servers or babysit a CLI. Lives in email; wants drafts waiting so she can triage in seconds. Cares about privacy and control.
- **Sam — self-hoster / privacy maximalist (secondary).** Wants everything local, will run a local model, may bring their own Google Cloud credentials. Values openness and "no data leaves my machine."

> **Item format:** every item has a bold title, a one-line summary, a user story (*As a … I want … so that …*), and acceptance criteria. See `CLAUDE.md` for backlog conventions.

---

## High Priority

> Resolved items are recorded in [`resolved.md`](./resolved.md). Item numbers are stable IDs — they are not reused or renumbered when items are completed.

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

29. **CD release automation** — *elevated from Medium 2026-08-13 (solo ship-fast strategy)*
    > **Status 2026-08-14:** workflow + `release.sh` fixes built on branch `release-automation` (`.github/workflows/release.yml`, `docs/ci-release.md`); awaiting secrets + the first tagged run to close (plus the carried Sparkle auto-update verification).
    Automate the item 11 release pipeline via GitHub Actions on tagged releases. Elevated because the solo, ship-fast-and-often strategy depends on near-zero distance from "code works" to "users have it" — a weekly Sparkle release cadence needs tagging a version to do everything. The manual pipeline shipped v0.1.0 live (2026-08-14, item 11 resolved) and surfaced the fixes below.
    *As a maintainer, I want tagged releases built and shipped automatically, so that cutting a release is one push, not a manual checklist.*
    - On a version tag, a workflow builds, signs, and notarizes the app and produces the DMG.
    - It publishes a GitHub release, updates the Sparkle appcast, and bumps the Homebrew cask.
    - Signing secrets are handled securely via encrypted CI secrets.
    - Mirrors the existing Prompter release workflow / `release-prep` skill steps.
    - **Fixes found during the v0.1.0 manual release (2026-08-14):** `release.sh` must propagate step failures (it exited 0 while the appcast step had failed); the appcast step must guard against stale artifacts in `dist/` (a leftover dry-run DMG with the same bundle version aborted `generate_appcast`); staple the notarization ticket to the **app before the DMG is built** (currently only the DMG gets stapled) ; modernize the cask's `depends_on macos: ">= :sonoma"` line, which trips a deprecation notice on install (all three tap casks share it).
    - **Launch smoke test (added 2026-08-14 after the v0.1.0 launch crash):** the pipeline MUST launch the exported, signed app and verify the process survives startup before publishing anything. v0.1.0 shipped notarized, Gatekeeper-accepted, and 905-tests-green yet crashed instantly at launch (missing `LD_RUNPATH_SEARCH_PATHS`; fixed on branch `fix-release-rpath`) — signatures and unit tests validate a binary without ever executing it, so an explicit launch check is the only gate that catches dyld-level breakage.
    - **Carried from item 11:** verify Sparkle auto-update end-to-end when the first 0.1.x ships through this pipeline — an installed v0.1.0 must discover, download, signature-verify, and install the update from the published appcast. (Unverifiable with only one release in existence.)

57. **Landing page / marketing site** — *⚠️ discussion required before building; lives in its own repo*
    The public site where people find the product, understand it in 30 seconds, and pay: positioning, pricing/checkout, download, and the Windows-demand waitlist.
    > **Do not start building from this item.** Scope, stack, hosting, domain, and copy need a dedicated discussion first, and the site goes in **its own repository**, not sentwise. This item exists so the work isn't forgotten and its requirements are captured.
    *As Marcus, I want to find the product, get what it does in 30 seconds, and start a trial without friction, so that trying it is easier than ignoring it.*
    - Positioning centered on the post-call follow-up workflow ("your follow-up is drafted before you're back from coffee") and the differentiators: no bot in your meetings, nothing stored in anyone's cloud, never training data, one price with the AI included.
    - **Training-data contrast (updated 2026-08-12 for the managed-inference decision):** cloud notetakers' own policies state customer call data (de-identified) is used to improve their models — e.g. Fathom's FAQ — and they store calls indefinitely. Our claim, stated accurately and without overreach: **"your calls are never stored on our servers and never train anyone's models"** — the managed proxy is stateless with zero-retention provider terms (item 56), and the BYO-key/local path removes us from the loop entirely. Copy must not blur the tiers: "we never even see your calls" belongs to the BYO/local option only.
    - Pricing page and checkout wired to the item 56 licensing/billing flow; prominent trial/download CTA.
    - **"Windows — join the waitlist"** email capture — the demand probe that decides if/when a cross-platform port (Tauri/Electron) is justified.
    - Basic discoverability: SEO fundamentals, OG/social cards, and a home for a demo video.
    - Held in a separate repo with its own deployment; all stack/hosting/analytics decisions deferred to the pre-build discussion.

## Medium Priority

20. **Voice profile refresh / re-learn**
    Keep the profile current.
    *As Priya, I want to re-learn my voice on demand or on a schedule, so that drafts keep up as my style changes.*
    - A "re-learn" action re-samples Sent and updates the profile.
    - Optional scheduled refresh interval in Settings.
    - Previous profile replaced atomically; a summary of changes shown.

22. **Cost & rate guardrails for cloud LLMs**
    Prevent surprise bills. *(Scope note 2026-08-12: with managed inference as the default, this item now serves the BYO-key escape hatch; the managed tier's metering and fair-use enforcement are server-side under item 56.)*
    *As Priya, I want usage limits and cost visibility for cloud providers, so that BYO-key drafting never surprises me.*
    - Token/usage tracked per run and per day.
    - Configurable caps pause drafting when exceeded, with a clear notification.
    - Estimated cost visible in the activity log/settings.

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

28. **Accessibility of the approval UI**
    Make the core loop usable for everyone.
    *As a keyboard/VoiceOver user, I want to review and approve drafts without a mouse, so that the app is usable for me.*
    - Popover and approval UI are fully VoiceOver-labeled and keyboard-navigable.
    - Approve/deny/edit actions have keyboard shortcuts.
    - Respects system Dynamic Type, contrast, and reduce-motion settings.

46. **Mailbox monitoring view (clutter breakdown by sender and age)**
    A summary of what is actually piling up in a mailbox, so the biggest sources of clutter are obvious before cleaning. Split out of item 42, which delivered the bulk-cleanup engine but deliberately deferred this reporting view.
    *As a user with a huge, neglected inbox, I want to see which senders and which date ranges account for most of my unread mail, so that I know what to clean up instead of guessing at filters.*
    - **Total/unread counts** for the selected mailbox, obtained without downloading it.
    - **Breakdown by sender/domain** — the top senders by message count, so a single newsletter flooding the inbox is immediately visible.
    - **Breakdown by age** — buckets (e.g. last 7 days, 30 days, this year, older) so stale mail is easy to spot.
    - **Never bulk-download:** counting must reuse item 42's bounded `SequenceWindow` walk (or IMAP `ESEARCH COUNT` where supported) so a mailbox of any size stays safe. A partial/capped scan must be labelled as such rather than presented as exact.
    - **One-click hand-off:** selecting a row (a sender, or an age bucket) fills the browser's filter so item 42's preview + confirm cleanup can act on it directly.
    - Ties to reply-worthiness filtering (item 17) for what counts as "junk," and to the activity log (item 21) for an audit trail. Open question still outstanding from item 42: whether any cleanup should ever run automatically vs. manual-only.

50. **Durable offline-queue dispatch intent across relaunch**
    An approved-while-offline draft's send/save intent should survive an app restart, so approval means "done" even if the user quits before reconnecting. Follow-up to item 27, whose merged implementation keeps the queued intent (send behavior + force flag) in memory only — the draft itself survives relaunch in the pending store, but its approved dispatch intent is forgotten.
    *As Priya, I want a reply I approved while offline to still dispatch automatically after I relaunch the app and reconnect, so that I never have to re-approve something I already decided.*
    - The queued dispatch intent (draft identity, send behavior, force flag) persists locally via `PersistenceService`, with rollback if the write fails.
    - On launch, persisted intents are restored; reconnect drains them through the normal approval path so all no-duplicate-send guards (item 27) still apply.
    - Deny, successful dispatch, account switch, and disconnect clear the persisted entry.
    - Note: a pre-review prototype of exactly this exists in `stash@{0}` (2026-08-06, includes `AppStateOfflineQueueReviewFeedbackTests`), but it predates the merged review-feedback rework — re-implement against current `main` rather than popping the stash.

58. **Model-consistency harness + eval suite for the follow-up pipeline**
    Engineering consistency across model paths. The managed-inference default (2026-08-12 decision) narrows the primary surface to one or two curated models we choose — but the harness still governs the BYO-key/local escape hatch, honest quality signaling on weaker local models, and safe swaps of the managed default as providers evolve. **Sequenced after item 51's first working version** — build 51 against the managed default, then grow the harness from the variance actually observed, not speculation.
    *As Marcus, I want the follow-up to be reliably good on the default; as Sam, I want it reliably good on whichever model I brought — so that approval is a tap, not a rewrite session.*
    - **Staged pipeline, not one big prompt:** extract action items/decisions into a structured intermediate (JSON) → build recap → render the email in the user's voice; defined input/output contracts per stage so model variance is contained, not compounded.
    - **Deterministic post-generation validation** (code, not the model): structure valid, action items present, length in bounds, no invented recipients, signature policy respected. Failure → retry with feedback, or a visible low-confidence signal in the approval UI.
    - **Per-model capability adaptation:** context-window size, structured-output/tool-calling support, instruction-following tier detected and adapted to (chunking for small-context local models, simplified prompts for weaker ones); honest UI messaging when a chosen model is below the quality bar.
    - **Golden-transcript eval suite:** fixed test transcripts (discovery call, demo, negotiation, messy multi-speaker) with assertions on what a good follow-up contains, runnable against every supported provider and the local-model path. This encodes what "good" looks like for a sales follow-up — domain specialization as software.
    - **Voice profile stays model-independent:** the learned style guide is injected identically regardless of provider, so switching models changes fluency, not identity.
    - The approval step remains the backstop: the bar is "consistently good enough that approval is a tap," not perfection.

59. **Onboarding: sign-in-and-go default + guided power-user model options**
    Assume every user is non-technical. The default onboarding is **sign in, start trial, draft** — managed inference (item 56) means no API keys, no provider choice, no billing beyond our checkout. The BYO-key/local path remains as a fully guided **power/privacy option in Settings**, never a gate in onboarding. *(Reworked 2026-08-12: originally specced a zero-key on-device default with a BYO wizard as the primary upgrade path; superseded same day by the managed-inference decision.)*
    *As Marcus, I want the app drafting for me minutes after install with nothing to configure, so that I never have to understand what an API key is; as Sam, I want a guided way to plug in my own key or local model, so that no server is ever in my loop.*
    - **Default path:** install → sign in / start trial → connect mailbox → drafting works. No model decisions surfaced at all.
    - **Power/privacy path (Settings, "Use your own AI"):** pick a provider → the app opens the exact key-creation console page → short numbered checklist (with screenshots) → paste → live test call → green check + "Saved to your Keychain." Mirrors the existing IMAP "Test Connection" pattern; the privacy upgrade ("we're never in the loop") stated plainly.
    - **OpenRouter one-click:** OpenRouter's PKCE flow provisions a key for the user with no manual copying — the featured easy path for BYO (one account, every major model behind one key).
    - **Honest about BYO friction:** the wizard states plainly that the provider will ask for payment details, so users aren't surprised mid-flow.
    - **Local-model option** (Ollama / on-device class) presented alongside BYO, with a quality-expectation note driven by the item 58 harness.
    - Key storage/validation reuses existing Keychain + connected-state UI conventions; disconnect/replace supported per provider; switching back to managed is one click.

52. **Calendar awareness: auto-fill follow-up recipients and context**
    Match an ingested transcript (item 51) to the call's calendar event so the follow-up is pre-addressed and context-enriched.
    *As Marcus, I want the follow-up pre-addressed to everyone on the meeting invite, so that I never copy email addresses by hand.*
    - Read-only access to the macOS Calendar via **EventKit** (local, no OAuth — any account the user's Calendar app syncs, including Google/M365, comes for free).
    - A transcript is matched to an event by time proximity (file timestamp / ingestion time vs. the event window); ambiguous matches are resolved by asking the user, never guessed silently.
    - Attendee emails pre-fill To/Cc (external attendees To, same-domain colleagues Cc — configurable), fully editable before approval.
    - Event title, attendee names/companies, and description enrich the drafting prompt.
    - Degrades gracefully: no matching event → the item 51 flow proceeds with empty recipients.

56. **Licensing, billing, and the managed-inference service (open core / paid binary)**
    The monetization plumbing behind the 2026-08-12 pricing decisions: public source, licensed binaries, subscription checkout, and — per the managed-inference decision — the stateless proxy that bundles drafting into the subscription so users never touch an API key.
    *As the maintainer, I want people to pay one price that includes the AI, so that non-technical buyers convert without becoming an LLM customer somewhere else; as Marcus, I want nothing to set up or pay for beyond the subscription itself.*
    - **Open core / paid binary:** source stays public on GitHub (self-compilers welcome); the signed, notarized, Sparkle-updating binary requires a license. The license is an **account/sign-in** (required for inference metering anyway).
    - **Managed-inference proxy:** app → serverless proxy → model provider. **Stateless by design** — no storage, no content logging, request/response held in memory only — under **zero-retention terms** with the provider. This design is load-bearing for the "no storage, no training" claim and must be verifiable in the public source.
    - **Metering & margin protection:** per-account token metering, rate limits, and abuse prevention; margin monitoring for the maintainer; a **fair-use policy in the pricing terms from day one** so heavy users don't silently eat the margin — with "switch to your own key for unlimited" (item 59) as the pressure-release valve.
    - Full-featured **trial** (14 days or first N calls — exact mechanic TBD); trial state survives reinstall reasonably.
    - **Individual** tier ~$15–20/mo or annual equivalent, **inference included** (unit cost is single-digit cents per follow-up); **Team** tier (3+ seats, adds CRM logging — item 55 — and centralized billing) as a follow-on; Enterprise explicitly parked.
    - Checkout via a **merchant-of-record** (Paddle / Lemon Squeezy class) so a solo maintainer isn't handling global sales tax; in-app license validation with an offline grace period (drafting may need the network; the app must not brick offline).
    - Final pricing, trial mechanics, and provider choices to be settled in the item 57 pre-build discussion.

62. **Cross-call deal memory (local) — continuity across follow-ups**
    Inspired by the momentum.io teardown (their "Deep Research" analyzes deal data across conversations — cloud-side, org-facing); ours is the local-first, rep-facing translation. Past transcripts and sent follow-ups already live on the user's machine — use them, so the third call with a prospect drafts like a third call, not a first.
    *As Marcus, I want the follow-up to a repeat call to reference what we agreed last time and carry forward unfinished action items, so that my emails read like a relationship, not a transaction.*
    - Ingested transcripts and their sent follow-ups are retained locally (bounded, user-clearable) and matched to a contact/deal by recipient email.
    - When a new transcript matches a prior contact, the drafting prompt receives a compact brief of the last call's agreed next steps and the sent follow-up.
    - Open action items from prior follow-ups that the new transcript doesn't resolve are surfaced ("still open from last time") for the user to keep or drop in review.
    - Everything stays on-device; the brief goes to the LLM only as part of the normal drafting call. No new server anything.
    - Foundation for a future pre-call brief (item 63).

63. **Pre-call brief (local)**
    The other half of item 62's memory: before a calendar-matched call (item 52), surface a one-glance brief — who, last call's outcomes, open action items, the last follow-up sent. Granola and momentum.io both validate the feature; ours is assembled entirely on-device.
    *As Marcus, I want a 30-second refresher before the call starts, so that I walk in remembering what we promised.*
    - A notification or menu-bar surface shortly before a calendar event whose attendees match a known contact (items 52 + 62).
    - Brief contains prior-call summary, open action items, and the last sent follow-up; nothing is fetched from any cloud.
    - Silent for first-time meetings or when no local history matches.

60. **Security-scoped bookmark for the watched transcript folder (if sandboxing lands)**
    The app is currently not sandboxed, so the item 51 watched folder works from a plain stored path. If the App Sandbox is enabled at distribution time (an item 11 decision), a stored path is no longer enough — the user's folder choice must persist as a security-scoped bookmark or watching silently breaks on relaunch. Flagged during the item 51 build (see `docs/post-call-followups.md`).
    *As Marcus, I want the watched folder to keep working across app updates and relaunches, so that auto-drafting doesn't silently die if the app hardens its sandbox.*
    - Decide at item 11 release time whether the distributed app enables the App Sandbox; record the decision here.
    - If sandboxed: the folder picker persists a security-scoped bookmark; launch resolves it and calls `startAccessingSecurityScopedResource`; a stale bookmark is detected and surfaced through the existing `transcriptFolderError` state ("choose the folder again in Settings").
    - If not sandboxed: close this item by documenting that decision.

65. **Native macOS Settings window (ContainerBar-style toolbar tabs + About pane)**
    The current Settings screen doesn't look or feel like a native macOS app. Restyle it to the pattern proven in the maintainer's ContainerBar app: a fixed-size settings window with a native `NSToolbar` of tab icons (à la System Settings / every polished menu-bar app), grouped-form panes, and a branded About tab.
    *As Marcus, I want Settings to look like a real Mac app, so that a tool asking for my email credentials feels trustworthy and polished.*
    - **Reference implementation** (read it, mirror the architecture): `~/Desktop/Current Projects/Container Bar App/ContainerBar/Sources/ContainerBar/Views/Settings/` — `SettingsWindow.swift` (a `SettingsTab` enum with SF Symbol icons + `SettingsWindowController: NSObject, NSToolbarDelegate` hosting per-tab SwiftUI panes in an `NSHostingController`, ~550×400), per-pane files (`GeneralSettingsPane`, `ConnectionSettingsPane`, …), and `AboutPane.swift`.
    - Native toolbar tabs with SF Symbols; window title follows the selected tab; fixed-size, non-resizable panes in macOS grouped-form styling (`.formStyle(.grouped)` sections with headers and footnote captions, like the screenshot's Display/Appearance/Startup groups).
    - Sentwise's existing pane views map across (suggested tabs): **General** (poll interval, send behavior + undo window, watched transcript folder, launch at login), **Account** (mail connection incl. provider guidance), **AI** (provider/model/key/test), **Rules** (sender allow/blocklist), **About**. Implementer may adjust the grouping; every existing setting and action must survive the move.
    - **About pane**: the Sentwise owl icon, app name, version + build read from the bundle (`CFBundleShortVersionString`/`CFBundleVersion`), copyright, links (GitHub repo, sentwise.ai), and the Check for Updates action — mirroring `AboutPane.swift`.
    - Onboarding keeps its own flow (this item restyles Settings, not the setup assistant); the item 64 fixes should land first or alongside so the Account pane inherits them.
    - VoiceOver labels and keyboard navigation preserved across the new chrome.

## Low Priority

30. **Slack approval channel**
    Optional Slack integration for users who live in Slack.
    *As a Slack-native user, I want drafts posted to Slack with approve/deny actions, so that approval fits my existing workflow.*
    - Opt-in, configured in Settings.
    - Posts drafts to a channel/DM with approve/deny actions.
    - Approve/deny routes through the same send/draft path as the native UX.

31. **Outlook / Microsoft 365 support**
    Add an Outlook/M365 provider behind the email-provider abstraction.
    *As an Outlook user, I want to connect my M365 mailbox, so that I can use sentwise without Gmail.*
    - Graph API + OAuth provider implementing the shared email-provider interface.
    - Feature parity with Gmail for read/draft/send.

32. **IMAP/SMTP connection (app password)** — *PRIMARY connection path*
    IMAP + Google app password is the primary way users connect (decided 2026-07-03, superseding OAuth item 3). Provider-agnostic, works for Gmail/Outlook/any IMAP host. Built on SwiftNIO (`swift-nio-imap`) in `Packages/SentwiseMail`.
    *As anyone, I want to connect by pasting my email + an app password, so that I skip Google Cloud setup entirely.*
    - ✅ `MailProvider` protocol + `IMAPMailProvider` (TLS connect + IMAP LOGIN/LOGOUT); "Test Connection" wired into Settings; app password stored in Keychain. **Live-verified against real Gmail 2026-07-04.**
    - ✅ Recent-message fetch (LOGIN → SELECT → FETCH UID+ENVELOPE → LOGOUT), newest first; sender/subject/date parsed; "Preview inbox" action in Settings. State machine + envelope parsing covered by EmbeddedChannel tests.
    - ✅ Body-text fetch (`UID FETCH BODY.PEEK[TEXT]`, streaming assembly over NIO, no `\Seen` flag set) + `MailBodyText` readable-text reduction (multipart, quoted-printable/base64, HTML-strip fallback). "View body" preview sheet in Settings. Covered by EmbeddedChannel + pure unit tests.
    - ✅ **Fetch + body live-verified** against real Gmail incl. `[Gmail]/Sent Mail` (2026-07-19).
   - ✅ **SMTP send live-verified against real Gmail (2026-08-13, branch `send-path-verify`):** the credential-gated `GmailLiveSendTests` dispatched a self-addressed reply through the production auto-send path and asserted delivery, addressing, threading, and the Sent Mail copy (see item 9 in `resolved.md`).
   - ⬜ **Remaining:** efficient `BODYSTRUCTURE`-guided fetch of just the `text/plain` part (avoids downloading attachments; also fixes single-part transfer-encoding decoding); handle missing provider-native features (push, labels) gracefully.

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

53. **Platform transcript integrations (Zoom first, Teams later)**
    Pull call transcripts automatically from the user's own meeting-platform account — no bot joins the call, nothing transits an sentwise server.
    *As Marcus, whose org records to Zoom cloud, I want new call transcripts picked up automatically, so that I never export a file by hand.*
    - **Zoom first:** poll the cloud-recordings API with the user's own credentials for newly completed transcripts. **Polling, not webhooks** — a local-first app has no public URL; a "dumb relay" push function (Cloudflare Worker/Lambda that forwards only a "new recording exists" ping, never the transcript) is a natural later upgrade now that the managed-inference service (item 56) means a server exists anyway.
    - Transcripts are fetched directly from the platform to the Mac and feed the item 51 `TranscriptSource` pipeline.
    - **Teams (Microsoft Graph) is a follow-on**; its tenant-admin-consent requirement must be documented honestly — same lesson as the parked BYO-OAuth path (item 3). Requires-IT-approval is expected for many orgs.
    - Per-platform setup friction (cloud recording enabled, plan requirements, credentials) documented; when the API path isn't available, degrade cleanly to item 51's file/folder ingestion.

54. **Native call capture + on-device transcription**
    Capture call audio locally and transcribe on-device. The biggest lift in the pivot; explicitly gated on item 51 proving demand.
    > **Competitive context (2026-08-12):** bot-free capture is being commoditized — Fathom now ships a bot-free desktop app, and Granola has been bot-free from day one (both still process calls in their cloud). The differentiation this item must protect is **on-device transcription** — audio and transcript never leave the Mac — not bot-free capture per se.
    *As Marcus, I want calls transcribed on my Mac with no bot joining and no audio leaving the machine, so that prospects never see "Notetaker has joined the meeting."*
    - System-audio + microphone capture via Core Audio process taps / ScreenCaptureKit, working across Zoom/Meet/Teams whether in a desktop app or a browser.
    - **On-device transcription** (Apple Speech / whisper.cpp class); speaker diarization is *not* required for v1 — a next-steps email doesn't need per-speaker attribution.
    - Call start/end detection (mic-in-use heuristics plus a manual control), with call-end automatically triggering the item 51 workflow.
    - A clearly visible "transcribing" indicator whenever capture is active, and a documented consent/disclosure story (two-party-consent jurisdictions) **before** this ships.
    - **Gate:** do not start until item 51 has paying/active users asking for automatic capture.

55. **CRM logging (HubSpot first, Salesforce later) — Team-tier differentiator**
    After a follow-up is approved, log the call summary and sent email to the CRM against the right contact/deal.
    *As Marcus's sales manager, I want call activity landing in the CRM without nagging reps, so that pipeline data reflects reality.*
    - After approval, optionally log the call summary + follow-up email to **HubSpot** (first; friendlier API/auth for individuals) or Salesforce, matched to contact/deal by attendee email.
    - Uses the user's own CRM credentials; calls go directly Mac → CRM, keeping the local-first promise.
    - Off by default, per-call opt-out; failures never block the email send itself.
    - Positioned as the **Team-tier** feature in the item 56 pricing model — the follow-up email sells to the rep, CRM hygiene sells to the manager who holds budget.

61. **Live exercise of the watcher → notification → approve loop**
    The one check split out of item 9 when it closed (2026-08-13): the full autonomous loop — a real fresh inbound message triggers watch → draft → native notification → approve → dispatch — has never been observed end-to-end on a live account with a watcher-produced draft. Both dispatch paths are now individually live-verified (items 9/44); this is about the loop as a whole, and daily dogfooding of the app will likely cover it naturally.
    *As the maintainer, I want the autonomous loop observed working end-to-end at least once on a live account, so that the core product promise is verified as a system, not just as parts.*
    - A fresh inbound message on a connected account produces a draft and a native notification without any manual triggering.
    - Approving from the notification dispatches per the configured send behavior (both settings observed, or the second covered by the item 9/44 live tests).
    - The observation is recorded (activity-history entries or a note here), then this item closes.
