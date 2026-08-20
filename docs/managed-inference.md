# Managed inference (item 56a)

Managed inference lets a signed-in Sentwise user draft email **without touching
an API key**. Drafting requests go through a stateless, zero-retention proxy
(`sentwise-service`) that authenticates the user's account and forwards to the
model provider under zero-data-retention terms. This is the default for new
installs; bring-your-own-provider remains the power/privacy path (item 59).

This document covers the app side. The proxy lives in its own public repo,
[`sentwise-service`](https://github.com/michaeltookes/sentwise-service), whose
README explains the no-storage/no-logging design.

## Pieces

| Piece | File | Role |
|---|---|---|
| Provider case | `Services/LLM/LLMTypes.swift` (`LLMProviderKind.managed`) | Default provider; `requiresAPIKey == false`, `supportsCustomBaseURL == false` |
| Client | `Services/LLM/ManagedInferenceClient.swift` | `LLMClient` calling `POST /v1/draft` with a Clerk session token |
| Session provider | `Services/Clerk/ManagedAccountService.swift` | Mints short-lived session tokens on demand; the `ManagedSessionProviding` behind `LLMService` |
| Sign-in | `Services/Clerk/ClerkClient.swift` | Native Clerk Frontend-API email-code flow |
| App state | `App/AppState+ManagedAccount.swift` | Sign-in/out actions + the 14→15 settings migration |
| UI | `Views/AIProviderControls.swift`, `Views/AIProviderSettingsView.swift` | Managed-first card + BYO behind a disclosure |

## Where the endpoint comes from

`ManagedInference.baseURL` is a compile-time constant
(`https://sentwise-inference.sentwise-service.workers.dev`) with a
`SENTWISE_INFERENCE_URL` environment override for dev/staging and the env-gated
live test.

## Trial

The trial is enforced **server-side** (14 days, full-featured). The Worker
stamps `trialStartedAt` into the account on the first authenticated draft and
returns a `402`-class structured error after expiry. The app maps that to
`LLMError.managedTrialExpired` and shows the plain message — never a raw HTTP
status.

## Sign-in: why the native Clerk Frontend API (not the clerk-ios SDK)

The locked decision was to use the clerk-ios SDK **if** it supports macOS and
builds cleanly via SPM, otherwise a browser hand-off or the Frontend API
directly. We chose to **implement Clerk's Frontend API email-code flow natively**
(no SDK). Rationale:

- **Zero new dependencies.** clerk-ios *does* declare `.macOS(.v14)`, but
  adopting it means adding a remote SPM dependency (and its transitive deps) to
  the Xcode project, and its prebuilt UI components are iOS-oriented and don't
  fit a macOS menu-bar app. A hand-rolled client adds nothing to a local-first,
  minimal-surface app.
- **Testability.** The flow is fully unit-tested against a fake transport
  (`ClerkClientTests`, `ManagedAccountServiceTests`), matching the app's existing
  LLM/IMAP client-testing pattern.
- **No URL scheme needed.** The app has no registered custom URL scheme, so a
  hosted-portal browser hand-off would have required net-new Info.plist wiring
  and a token hand-back the hosted portal doesn't natively provide for native
  apps.

### The native mechanism

Clerk's native (non-browser) auth uses an `Authorization: Bearer <clientToken>`
header on every Frontend-API request (empty on the first call). Clerk returns a
rotated client (device) token in the `Authorization` response header, which we
store in the Keychain and echo on the next request. No `Origin` header is sent
(that would put Clerk into browser/cookie mode). Requests are marked native with
`?_is_native=1`.

The email-code flow:

1. `POST /v1/client/sign_ins` with `identifier=<email>` → sign-in id +
   `email_address_id`.
2. `POST /v1/client/sign_ins/{id}/prepare_first_factor` (`strategy=email_code`)
   → sends the code email.
3. `POST /v1/client/sign_ins/{id}/attempt_first_factor` (`strategy=email_code&code=…`)
   → `status=complete` + `created_session_id`.
4. `POST /v1/client/sessions/{session_id}/tokens` → `{ "jwt": … }`, the
   short-lived session token the Worker verifies. Refreshed by calling again;
   `ManagedInferenceClient` mints a fresh one per draft.

The Keychain holds the device token (`managed.clientToken`) and session id
(`managed.sessionID`); the account email is stored in (non-secret) settings for
the "Connected as …" display.

### Scope notes / live verification

- **Google sign-in is deferred within 56a.** Email code is the enabled primary
  method; native Google OAuth is a later item (59/onwards).
- The native flow is implemented to Clerk's Frontend-API spec. It is fully
  unit-tested, but a real end-to-end sign-in against the live dev instance
  (which needs an email inbox for the code) has **not** been exercised in CI.
  The env-gated live test (`ManagedInferenceLiveTests`) verifies the **Worker**
  (`/v1/me`, `/v1/draft`) with a manually supplied session token via
  `SENTWISE_LIVE_CLERK_SESSION_TOKEN` + `SENTWISE_INFERENCE_URL`.

## Settings migration (14 → 15)

On first launch at schema 15, an install with **no configured BYO provider** (no
stored API key and no verified model) moves to `.managed`. A configured BYO user
keeps their provider. Fresh installs default to `.managed` directly. The
migration is gated on the original schema version so it runs once
(`AppState.migratedManagedInferenceSettings`).

## Prowl hunt mode

`LLMService` returns a `StubManagedInferenceClient` (deterministic canned
response, zero network) whenever `ProwlHuntRuntime.current.isEnabled`, and the
sign-in controls are disabled in hunt mode, so hunts stay offline-safe. The new
sign-in controls carry `accessibilityIdentifier`s documented in
`.prowl/README.md` and are added to `forbiddenSelectors` in `.prowl/config.yml`.
