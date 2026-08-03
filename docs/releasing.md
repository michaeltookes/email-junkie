# Releasing Email Junkie

The full runbook for cutting a signed, notarized, auto-updating release of the
Email Junkie menu-bar app. This covers the **manual** pipeline; CI automation
(backlog item 29) is deliberately out of scope.

Everything credential-related is supplied at release time through environment
variables — **nothing is stored in the repo**. The scaffolding (scripts, cask
template, Sparkle wiring, DMG assets) lives under `Distribution/`.

---

## What's in the repo vs. what you supply

| In the repo (this branch) | You supply at release time |
| --- | --- |
| `Distribution/scripts/release.sh` — the pipeline | Developer ID Application cert (in login Keychain) |
| `Distribution/scripts/make-dmg.sh` / `make-icns.sh` | notarytool keychain profile |
| `Distribution/assets/**` — branded DMG background + icon masters | Sparkle EdDSA **private** key (in login Keychain) |
| `Distribution/email-junkie.rb` — Homebrew cask template | The real `SUPublicEDKey` (paste into `Info.plist` once) |
| `EmailJunkie/Info.plist` — Sparkle feed URL + **placeholder** public key | |

---

## One-time prerequisites

1. **Apple Developer ID Application certificate**
   Installed in your login Keychain. Confirm:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
   Note the identity string and your 10-character Team ID.

2. **notarytool keychain profile**
   Store an app-specific password (from appleid.apple.com) once:
   ```bash
   xcrun notarytool store-credentials "EmailJunkie-Notary" \
     --apple-id "you@example.com" \
     --team-id "YOURTEAMID" \
     --password "app-specific-password"
   ```
   `EmailJunkie-Notary` is then your `NOTARY_PROFILE`.

3. **Sparkle EdDSA signing keypair** — generate **once, ever**
   Use Sparkle's `generate_keys` (ships in the Sparkle SPM artifact bundle, or
   download the Sparkle release tools):
   ```bash
   ./bin/generate_keys
   ```
   - The **private** key is stored in your login Keychain automatically — never
     commit it, never print it into the repo.
   - It prints the **public** key. Paste that base64 string into
     `EmailJunkie/Info.plist` as `SUPublicEDKey`, replacing the all-`A`
     placeholder. Commit that one-line change.
   - To recover the public key later: `./bin/generate_keys -p`.

   > Until this real key is in `Info.plist`, the app still launches and runs —
   > it just rejects any downloaded update because signature verification fails.

4. **Tooling**: `create-dmg` (`brew install create-dmg`) and Sparkle's
   `generate_appcast` / `sign_update`. Point `SPARKLE_BIN` at the directory
   holding those two tools if they aren't on your `PATH`.

5. **Homebrew tap** lives at `~/Desktop/Current Projects/homebrew-tap`
   (`michaeltookes/homebrew-tap`). The cask is only added/updated there at
   actual release time — this repo just carries the template.

---

## Versioning

- `MARKETING_VERSION` (currently `0.1.0`) is the human version — bump per
  release.
- `CURRENT_PROJECT_VERSION` is an integer Sparkle compares as `CFBundleVersion`
  — bump it every release, even for the same marketing version, so Sparkle can
  order builds.
- Both can be overridden per run: `release.sh --version 0.2.0 --build 5`.

---

## Dry run (no credentials needed — do this first)

Proves the archive → DMG path and the branded layout without any signing:

```bash
Distribution/scripts/release.sh --dry-run
```

Output lands in the gitignored `dist/`:
- `dist/EmailJunkie-<version>.dmg` — unsigned, for layout inspection only
- `dist/EmailJunkie-<version>.dmg.sha256`

Open the DMG to confirm the background art and drag-to-Applications layout, then
detach it. **Do not distribute a dry-run DMG** — it is unsigned and
un-notarized, so Gatekeeper will block it on other machines.

---

## Full signed release

```bash
export SIGNING_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)"
export DEVELOPMENT_TEAM="YOURTEAMID"
export NOTARY_PROFILE="EmailJunkie-Notary"
# export SPARKLE_BIN="/path/to/Sparkle/bin"   # if not on PATH

Distribution/scripts/release.sh --version 0.1.0 --build 1
```

What `release.sh` does, step by step:

1. **Archive** the `EmailJunkie` scheme in Release, stamping the version/build.
2. **Export** a Developer-ID-signed `.app` (hardened runtime, secure timestamp)
   via a generated `ExportOptions.plist`. It then **hard-aborts if the built
   app's `SUPublicEDKey` is still the placeholder** (or empty), so a signed
   release can never ship with auto-update silently broken — generate the real
   key (prerequisite 3) and update `Info.plist` first.
3. **Stage** the app as `Email Junkie.app` so the DMG icon label reads as the
   brand name.
4. **Build the DMG** with the branded background (`make-dmg.sh`, fixed geometry).
5. **Notarize** the DMG (`notarytool submit --wait`) and **staple** the ticket.
6. **Appcast + checksums**: `generate_appcast dist/` signs the DMG with the
   EdDSA private key and writes `dist/appcast.xml`; a `.sha256` is written too.

---

## Publishing

1. Create a GitHub release tagged `v<version>` on
   `github.com/michaeltookes/email-junkie`.
2. Upload **both** `EmailJunkie-<version>.dmg` and `appcast.xml` as release
   assets. The app's `SUFeedURL` points at
   `releases/latest/download/appcast.xml`, so the appcast must be an asset on
   the release marked **latest**.
3. **Homebrew cask**: copy `Distribution/email-junkie.rb` into the tap at
   `~/Desktop/Current Projects/homebrew-tap/Casks/`, set `version` and the DMG
   `sha256` (from the `.sha256` file), then commit/push the tap. Users install
   with:
   ```bash
   brew install --cask michaeltookes/tap/email-junkie
   ```

---

## Update flow (how users get new versions)

- On launch, Sparkle quietly checks the appcast (`SUEnableAutomaticChecks`).
- The menu's **Check for Updates…** item triggers an interactive check.
- Sparkle downloads the new DMG and verifies it against `SUPublicEDKey` before
  installing — which is why the real key must ship in the first release.
