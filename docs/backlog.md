# Backlog

Prioritized list of planned features, improvements, and technical debt for **email-junkie** — a native, local-first macOS assistant that learns your voice from your Sent mail and drafts email on your behalf for one-tap approval. Its **flagship workflow (2026-08-12 pivot)** is the **post-call follow-up**: when a call ends, ingest the transcript and draft the next-steps email in the user's voice. Inbox reply drafting remains, as one workflow among several.

**Product direction (updated 2026-08-12):**
- **Flagship workflow:** transcript in → next-steps follow-up email out, in the user's voice (items 51–55). The existing drafting → approval → send plumbing is reused; transcript acquisition is the new subsystem, phased: file/paste ingestion first (51), calendar awareness (52), platform APIs (53), native no-bot capture last (54).
- **Primary commercial ICP:** Account Executives / salespeople in high-velocity roles (see **Marcus** persona). Priya remains the persona for the inbox-reply workflow.
- **No-bot promise:** calls are never joined by a bot. Transcripts come from local files, the user's own platform APIs, or (future) on-device capture. This is a core differentiator vs. Fathom/Fireflies/Gong-style cloud notetakers.
- **Monetization (supersedes the original "no subscription" ethos line):** open core / paid binary — source stays public, signed auto-updating binaries are licensed. Subscription pricing: trial → Individual ~$15/mo → Team tier with CRM logging (items 55–56). Enterprise is explicitly parked.

**v1 design decisions:**
- **Platform:** native macOS menu-bar app (Swift), following the Prompter distribution pattern (DMG + Homebrew cask + Sparkle auto-update). **Affirmed over an Electron rewrite 2026-08-12** — validate on macOS first (the ICP skews Mac); measure Windows demand via a landing-page waitlist (item 57) and revisit Tauri/Electron only if it fills.
- **Approval channel:** native macOS notification first. (Slack is a future item.)
- **Email provider:** Gmail first. (Outlook/M365 and IMAP/SMTP are future items.)
- **Send behavior:** user-configurable — auto-send on approve *or* save-as-draft.
- **LLM access:** pluggable BYO-any-provider **and** a local-model option.
- **Ethos:** local-first, private, BYO-key. Data stays on the user's machine except the LLM call (which the user controls). *(The original "no subscription" clause was superseded 2026-08-12 — see Monetization above.)*

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

9. **Send / save-as-draft (user-configurable)** — *in progress (send + save-as-draft + toggle done; live-verify remaining)*
   On approval, either send immediately or create a Gmail draft, per a setting.
   *As Priya, I want to choose whether approval sends immediately or just saves a Gmail draft, so that I can match my own comfort/trust level.*
   - ✅ **Draft-only:** a native Gmail draft is created via IMAP `APPEND` to `[Gmail]/Drafts` (`\Draft` flag), addressed to `Reply-To` when present, and threaded via `In-Reply-To`/`References` from the captured source Message-ID. RFC 822 builder (base64 body, RFC 2047 subject) + APPEND state machine covered by unit + EmbeddedChannel tests.
   - ✅ **Auto-send:** reply submitted over a hand-rolled **SMTP** client on NIO (implicit TLS on 465, `AUTH LOGIN`, `MAIL FROM`/`RCPT TO`/`DATA` with dot-stuffing). Reuses the same RFC 822 builder for correct subject/threading; SMTP host derived from the IMAP host (`imap.` → `smtp.`). Response decoder + send state machine covered by EmbeddedChannel tests.
   - ✅ **Toggle:** `SendBehavior` setting (save-as-draft vs auto-send, schema v5) with a "On approve" picker in Settings; `approveGeneratedDraft()` dispatches to send or save. The draft preview's action reflects the choice ("Send now" vs "Save to Drafts").
   - ✅ The approval UI indicates what "Approve" will do — the Review Drafts window (item 8) shows "Approve will send/save" and labels the button accordingly; the Settings preview also reflects it.
   - ✅ **Save-as-draft live-verified end-to-end against real Gmail (2026-07-19):** an approved reply appeared in Gmail → Drafts, correctly addressed and threaded under the original message.
   - ⬜ **Remaining (deferred by user for a later, self-addressed test):** live-verify the **auto-send (SMTP)** path against real Gmail, and exercise the watcher → notification → approve path with a real watcher-produced draft (item 8) once a fresh message arrives.

11. **Distribution: signed DMG + Sparkle + Homebrew cask** — *scaffolding built (branch `distribution-pipeline`); live signed release remaining*
    Reuse the Prompter shipping pipeline.
    > **Scaffolding landed 2026-08-03 (branch `distribution-pipeline`):** the code/asset half is in the repo — branded app icon, DMG assets, a credential-parameterized release pipeline with a proven unsigned dry-run, Sparkle wiring (placeholder key), the cask template, and the release runbook. The ⬜ items below can only be met by an actual signed release using the user's Developer ID cert, notarytool profile, and a real EdDSA keypair — done later via the release-prep skill (see [`releasing.md`](./releasing.md)). CI automation of this pipeline is item 29.
    *As Priya, I want to install via DMG or Homebrew and get automatic updates, so that setup and upkeep are frictionless and not scary.*
    - ✅ Branded app icon compiled into the app (AppIcon asset catalog, verified `CFBundleIconName`) and DMG background/icon masters vendored under `Distribution/`.
    - ✅ Release pipeline `Distribution/scripts/release.sh` (archive → export → notarize → DMG → appcast → checksums), all credentials via env vars; unsigned `--dry-run` verified to build the branded DMG (volume "Email Junkie", drag-to-Applications, branded background, staged "Email Junkie.app", 0.1.0).
    - ✅ Sparkle 2.x integrated as an SPM dependency and wired via `SPUStandardUpdaterController`; `SUFeedURL` + `SUEnableAutomaticChecks` set in Info.plist.
    - ✅ Homebrew cask template `Distribution/email-junkie.rb` (house style) and full release runbook `docs/releasing.md`.
    - ⬜ Signed, notarized DMG installs without Gatekeeper "unidentified developer" warnings — needs the Developer ID cert + notarytool profile at release time.
    - ⬜ Homebrew cask published live in the tap with the real DMG `sha256`.
    - ⬜ Sparkle auto-update verified against a published appcast — needs the real EdDSA keypair (replace the placeholder `SUPublicEDKey`).

44. **Live end-to-end verification of a non-Gmail (att.net) account** — *mostly verified; only save-as-draft remains*
    Connect a real `att.net` (Yahoo-backed) account and confirm the whole IMAP path end-to-end, the way Gmail was live-verified (items 6/9).
    *As Priya with a neglected att.net inbox, I want to connect it and actually see my mail, so that I can trust the app before it acts on that account.*
    - ✅ **Authenticate:** email + AT&T Secure Mail Key over `imap.mail.att.net` passes "Test Connection". *(Verified live, branch `attnet-verify`.)*
    - ✅ **Inbox browsing:** the mailbox browser loads and pages a genuinely huge, unread-heavy Inbox without loading it whole — the crash that motivated items 45/49. *(Verified live.)*
    - ✅ **Folder resolution:** Sent/Drafts load; "All Mail" correctly hidden; live **Trash** and **Archive** folder names confirmed by successful moves during the item-49 sweep verification. *(Verified live.)*
    - ⬜️ **Save-as-draft:** a reply saved as a draft lands in att.net Drafts, correctly addressed and threaded (mirrors the Gmail check in item 9). **Still to verify** — the one remaining criterion.
    - Any folder-name mismatch found is fixed in `MailboxNaming`. *(None found; `Trash`/`Archive`/`Sent`/`Draft` all correct.)*

51. **Post-call follow-up workflow: transcript in → next-steps email out** — *v1 of the 2026-08-12 pivot; the flagship workflow*
    Ingest a finished call's transcript and draft the follow-up email in the user's voice, through the existing approval → send/save pipeline. Deliberately no capture and no platform integrations — the transcript arrives as a file or paste. This validates the core value proposition using ~90% existing plumbing before any investment in transcript acquisition (items 52–54).
    *As Marcus, I want my next-steps follow-up drafted from the call transcript before I'm back from getting coffee, so that post-call admin stops eating my selling time.*
    - Transcript ingestion by **paste** and by **file** (`.txt`, `.vtt`, `.srt`, `.md` — the formats Zoom/Teams/notetakers export), via the menu-bar UI including drag-and-drop.
    - Optional **watched folder** (e.g. Zoom's local recording directory): a new transcript file appearing there triggers the workflow automatically.
    - A **`TranscriptSource` abstraction** so future sources (platform APIs — item 53, native capture — item 54) plug in the way LLM providers do.
    - The LLM reads the full transcript and drafts a follow-up in the user's learned voice: brief recap, agreed next steps / action items with owners, proposed next meeting. Prompting must handle transcripts both with and without speaker labels.
    - Recipients are user-editable before approval (auto-fill is item 52's job); the draft flows through the existing notification → approve → send/save-as-draft path unchanged.
    - Works with BYO cloud providers and the local-model option; long transcripts are handled within model context limits (chunk/summarize as needed) rather than failing.

57. **Landing page / marketing site** — *⚠️ discussion required before building; lives in its own repo*
    The public site where people find the product, understand it in 30 seconds, and pay: positioning, pricing/checkout, download, and the Windows-demand waitlist.
    > **Do not start building from this item.** Scope, stack, hosting, domain, and copy need a dedicated discussion first, and the site goes in **its own repository**, not email-junkie. This item exists so the work isn't forgotten and its requirements are captured.
    *As Marcus, I want to find the product, get what it does in 30 seconds, and start a trial without friction, so that trying it is easier than ignoring it.*
    - Positioning centered on the post-call follow-up workflow ("your follow-up is drafted before you're back from coffee") and the differentiators: no bot in your meetings, local-first/private, BYO-key.
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
    Prevent surprise bills.
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

29. **CD release automation**
    Automate the item 11 release pipeline via GitHub Actions on tagged releases.
    *As a maintainer, I want tagged releases built and shipped automatically, so that cutting a release is one push, not a manual checklist.*
    - On a version tag, a workflow builds, signs, and notarizes the app and produces the DMG.
    - It publishes a GitHub release, updates the Sparkle appcast, and bumps the Homebrew cask.
    - Signing secrets are handled securely via encrypted CI secrets.
    - Mirrors the existing Prompter release workflow / `release-prep` skill steps.

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

52. **Calendar awareness: auto-fill follow-up recipients and context**
    Match an ingested transcript (item 51) to the call's calendar event so the follow-up is pre-addressed and context-enriched.
    *As Marcus, I want the follow-up pre-addressed to everyone on the meeting invite, so that I never copy email addresses by hand.*
    - Read-only access to the macOS Calendar via **EventKit** (local, no OAuth — any account the user's Calendar app syncs, including Google/M365, comes for free).
    - A transcript is matched to an event by time proximity (file timestamp / ingestion time vs. the event window); ambiguous matches are resolved by asking the user, never guessed silently.
    - Attendee emails pre-fill To/Cc (external attendees To, same-domain colleagues Cc — configurable), fully editable before approval.
    - Event title, attendee names/companies, and description enrich the drafting prompt.
    - Degrades gracefully: no matching event → the item 51 flow proceeds with empty recipients.

56. **Licensing, trial, and subscription billing (open core / paid binary)**
    The monetization plumbing behind the 2026-08-12 pricing decision: public source, licensed binaries, subscription checkout.
    *As the maintainer, I want people to be able to pay for email-junkie, so that the product sustains itself; as Marcus, I want a full-featured trial, so that the workflow proves itself before I pay.*
    - **Open core / paid binary:** source stays public on GitHub (self-compilers welcome); the signed, notarized, Sparkle-updating binary requires a license.
    - Full-featured **trial** (14 days or first N calls — exact mechanic TBD); trial state survives reinstall reasonably.
    - **Individual** tier ~$15/mo or ~$120/yr; **Team** tier (3+ seats, adds CRM logging — item 55 — and centralized billing) as a follow-on; Enterprise explicitly parked.
    - Checkout via a **merchant-of-record** (Paddle / Lemon Squeezy class) so a solo maintainer isn't handling global sales tax; license issuance + in-app validation with an offline grace period (a local-first app must not phone home per-launch).
    - Final pricing, trial mechanics, and provider choice to be settled in the item 57 pre-build discussion.

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
    - ✅ **Fetch + body live-verified** against real Gmail incl. `[Gmail]/Sent Mail` (2026-07-19).
   - ⬜ **Remaining:** live-verify **SMTP send** against real Gmail (built; deferred with item 9's auto-send test); efficient `BODYSTRUCTURE`-guided fetch of just the `text/plain` part (avoids downloading attachments; also fixes single-part transfer-encoding decoding); handle missing provider-native features (push, labels) gracefully.

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
    Pull call transcripts automatically from the user's own meeting-platform account — no bot joins the call, nothing transits an email-junkie server.
    *As Marcus, whose org records to Zoom cloud, I want new call transcripts picked up automatically, so that I never export a file by hand.*
    - **Zoom first:** poll the cloud-recordings API with the user's own credentials for newly completed transcripts. **Polling, not webhooks** — a local-first app has no public URL; a "dumb relay" push function (Cloudflare Worker/Lambda that forwards only a "new recording exists" ping, never the transcript) is a possible later latency upgrade.
    - Transcripts are fetched directly from the platform to the Mac and feed the item 51 `TranscriptSource` pipeline.
    - **Teams (Microsoft Graph) is a follow-on**; its tenant-admin-consent requirement must be documented honestly — same lesson as the parked BYO-OAuth path (item 3). Requires-IT-approval is expected for many orgs.
    - Per-platform setup friction (cloud recording enabled, plan requirements, credentials) documented; when the API path isn't available, degrade cleanly to item 51's file/folder ingestion.

54. **Native call capture + on-device transcription (the no-bot moat)**
    Capture call audio locally and transcribe on-device — the Granola-style capture path that makes the no-bot promise total. The biggest lift in the pivot; explicitly gated on item 51 proving demand.
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
