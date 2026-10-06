# Release tools

These scripts turn a commit into a signed, notarized Pitot DMG and a signed Sparkle appcast. Publishing is done by hand. No secret is stored in the repo: the notarization password and the update signing key stay in your login keychain.

| File | What it does |
|---|---|
| `release.sh` | Builds Release, signs inside-out with Developer ID, notarizes and staples the app, builds the DMG, signs, notarizes and staples the DMG |
| `appcast.sh` | Runs Sparkle's `generate_appcast` from the pinned 2.10.0 zip, then checks the appcast |
| `test/appcast-selftest.sh` | Tests the checks in `appcast.sh` with stubs for `generate_appcast`, `codesign`, `stapler` and `spctl`. No network, no keychain |
| `out/` | DMGs, `appcast.xml`, and notarization logs on failure. Git ignores it |

## If you fork Pitot

`App/project.yml` holds the original author's Apple team and bundle id: `DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER` and `bundleIdPrefix`. Anyone who forks the project must change them to their own before building a release. `release.sh` reads the team from that file, and `appcast.sh` reads the bundle id from it.

## One-time setup

You run these yourself. Each one touches your keychain or your Apple account. Below, `<TEAM ID>` is the 10-character Team ID of your Apple developer account.

**1. Tools.** Install XcodeGen with `brew install xcodegen`. A `Developer ID Application: <Your Name> (<TEAM ID>)` certificate must be in the login keychain. Check with `security find-identity -v -p codesigning`. `release.sh` uses the first Developer ID Application identity of the team in `App/project.yml`, or the identity in `PITOT_SIGN_IDENTITY`.

**2. Notarization profile.** Create an app-specific password at appleid.apple.com, under Sign-In and Security. Then run:

```bash
xcrun notarytool store-credentials "pitot-notary" --apple-id "<your Apple ID email>" --team-id <TEAM ID>
```

It asks for the app-specific password at a secure prompt. Type it only there. Never put it on a command line, in a file, or in the repo, and do not add `--sync`. Check the profile with `xcrun notarytool history --keychain-profile pitot-notary`.

**3. Update signing key.** Other apps on your Mac may already keep a Sparkle key in your login keychain, under Sparkle's default account `ed25519`. Pitot uses its own account, `pitot`, so it never signs with that key, and you back up the Pitot key separately with `generate_keys --account pitot -x`.

Use `generate_keys` from the same pinned Sparkle zip as the app:

```bash
cd "$(mktemp -d)"
curl -fLO https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip
shasum -a 256 Sparkle-for-Swift-Package-Manager.zip
# must print 17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959. Stop if it does not.
unzip -q Sparkle-for-Swift-Package-Manager.zip 'bin/*'
./bin/generate_keys --account pitot
```

- `generate_keys --account pitot` saves a new private key in your login keychain and prints its public key. Always pass `--account pitot`: without it, the tool returns the other app's key.
- Put the public key in `App/project.yml` as `PITOT_SPARKLE_PUBLIC_KEY`. The public key is not a secret. Print it again with `./bin/generate_keys --account pitot -p`.
- Set `PITOT_FEED_URL` in `App/project.yml` to the HTTPS address of the published `appcast.xml`.
- Back up the private key once: `./bin/generate_keys --account pitot -x pitot-sparkle-key.txt`. Move the file to encrypted, offline storage, for example an encrypted disk image kept off this Mac. Then delete the copy here. Never commit it, mail it, or paste it anywhere.

`release.sh` refuses a notarized release while `PITOT_SPARKLE_PUBLIC_KEY` is empty or `PITOT_FEED_URL` is still the `.invalid` placeholder, because that app could never update itself.

## Release checklist

Do these in order. Stop at the first failure.

1. **Choose the version.** It must be higher than every published version. `release.sh` sets both `CFBundleShortVersionString` and `CFBundleVersion` to it on the xcodebuild command line, so no file changes. Sparkle compares `CFBundleVersion`, so never reuse a version.
2. **Check the catalog** against the live docs: `cd Tools/catalog-check && npm ci && node check.js`.
3. **Run all tests:**
   ```bash
   (cd Core && swift build && swift test)
   (cd Tools/oracle && node run.js --check)
   (cd App && xcodegen generate && xcodebuild -scheme Pitot -destination 'platform=macOS' test)
   Tools/release/test/appcast-selftest.sh
   ```
4. **Commit everything.** `release.sh` refuses a tree with changes or untracked files.
5. **Build:** `PITOT_NOTARY_PROFILE=pitot-notary Tools/release/release.sh --version X.Y.Z`. It ends by printing the DMG path, its SHA-256 and its size. Keep the SHA-256.
6. **Try the DMG** on a second user account: open it, drag Pitot to Applications, and launch it. There must be no Gatekeeper warning.
7. **Prepare the feed folder:** a new folder with only `Pitot-X.Y.Z.dmg` and the currently published `appcast.xml`, if there is one. The existing appcast keeps earlier releases in the feed.
8. **Make the appcast:**
   ```bash
   PITOT_TEAM_ID=<TEAM ID> Tools/release/appcast.sh --dmg-dir <feed folder> \
     --download-url-prefix https://github.com/<owner>/<repo>/releases/download/vX.Y.Z/ \
     --release-notes <notes.md> --confirm-keychain
   ```
   `PITOT_TEAM_ID` is required: the script never assumes a team. macOS may ask to allow access to the key in your keychain. The script writes `Tools/release/out/appcast.xml` only when every check passes.
9. **Publish by hand:**
   - Tag the commit `vX.Y.Z` and push the tag.
   - Create the GitHub release `vX.Y.Z` and upload the DMG with its exact file name.
   - Download the asset again and compare its SHA-256 with step 5.
   - Check that the release download URL is exactly the enclosure URL in `appcast.xml`.
   - Publish `appcast.xml` at `PITOT_FEED_URL`, then check that `curl -fsSI <PITOT_FEED_URL>` answers 200 over HTTPS.
   - Update an installed earlier version through "Check for Updates…".

For a dry run, add `--dry-run` to either script: it prints each command and changes nothing. `release.sh --skip-notarize --allow-dirty` makes a local build named `Pitot-X.Y.Z-unnotarized.dmg`. Never publish it. `appcast.sh` refuses it.

## What the scripts check

`release.sh`:
- Builds into a new temporary folder with the package versions from `App/Package.resolved` only.
- Signs inside-out, without `--deep`: Sparkle's `Installer.xpc` and `Downloader.xpc`, `Updater.app`, `Autoupdate`, `Sparkle.framework`, then the app. Xcode signs only the framework and the app, and leaves Sparkle's helpers ad-hoc signed, which notarization rejects.
- Checks that every executable in the app has a Developer ID signature of the team in `App/project.yml`, the hardened runtime flag, and a secure timestamp.
- Fails if the app has `get-task-allow`, `disable-library-validation`, `allow-unsigned-executable-memory` or a similar entitlement. The app needs no entitlements.
- Requires notarization status `Accepted` for the app and the DMG. On failure it saves Apple's log in `out/` and prints the submission id.
- Checks `stapler validate`, the DMG contents (`Pitot.app` and an `Applications` link), and `spctl` for both.

`appcast.sh`:
- Works on a private copy of the DMG, so the file cannot change between the checks and the signature.
- Before anything is signed, requires: a stapled DMG and app that Gatekeeper (`spctl`) accepts, the bundle id from `App/project.yml` (or `PITOT_BUNDLE_ID`), a non-empty `SUPublicEDKey`, an HTTPS `SUFeedURL`, and dotted version numbers. `--allow-unnotarized` skips only the stapled-ticket and Gatekeeper checks.
- Checks signatures with a code requirement that `codesign` evaluates itself, never by reading its text output: a Developer ID Application certificate under Apple's root, with the team in `PITOT_TEAM_ID`. This applies to the DMG, the app (plus its bundle id), `Sparkle.framework`, and every executable file in the app. An ad-hoc or foreign-team build is refused.
- Keeps the Sparkle 2.10.0 zip in a private cache folder: `$TMPDIR/pitot-release`, or `~/Library/Caches/pitot-release` when `TMPDIR` is unset or `/tmp`. It refuses a cache folder that is a symlink, belongs to another user, or is writable by others.
- Copies the zip into its own private temporary folder, checks the SHA-256 of that copy, and unpacks and runs only that copy. On a mismatch it deletes the cached zip and stops.
- Signs with the keychain account in `PITOT_SPARKLE_ACCOUNT`, default `pitot`. It refuses the shared default account `ed25519`.
- Runs `generate_appcast --account pitot --maximum-deltas 0` on a copy of the folder. It never passes a key: `generate_appcast` reads it from the keychain.
- Stops if the key is missing or does not match the app's `SUPublicEDKey`.
- Checks the result: HTTPS URLs only, a `sparkle:edSignature` on every enclosure, a feed signature, no `.delta` update, and a `sparkle:version` equal to the app's `CFBundleVersion`.

`generate_appcast` keeps extracted archives in `~/Library/Caches/Sparkle_generate_appcast`. You can delete that folder after a release.

## Key loss and rotation

Sparkle checks two signatures on every update: the EdDSA signature against `SUPublicEDKey`, and the Apple code signature, which must come from the same Developer ID team as the installed app. So every release must be signed by the same team. A renewed Developer ID certificate keeps the team, so renewal is safe.

- **EdDSA key lost.** Make a new key and put its public key in the app. Sign that release with the new key. Installed copies accept it because the Team ID matches. This fallback works because `SUVerifyUpdateBeforeExtraction` is on. Sparkle's behavior without it was not verified.
- **EdDSA key leaked.** Rotate the same way, then delete the old key and its backups. `generate_keys` keeps an existing key, so remove the old item from the login keychain first. It is the item named `https://sparkle-project.org`, account `pitot`. Do not touch an item with account `ed25519`: it may belong to another app.
- **EdDSA key and Developer ID both lost.** Installed copies cannot be updated. Users must download and install the new version by hand.

## Security checklist

- [ ] The tree was clean and the commit is tagged.
- [ ] The notarization password exists only in the keychain profile.
- [ ] The EdDSA private key exists only in the login keychain and in one encrypted offline backup.
- [ ] The appcast was signed with the `pitot` account, never the shared `ed25519` one.
- [ ] No key was passed on a command line or in an environment variable.
- [ ] The DMG is notarized and stapled. No `-unnotarized` file was published.
- [ ] The feed URL and the download URL are HTTPS.
- [ ] The appcast has no delta updates.
- [ ] Sparkle's tools came from the 2.10.0 zip with the checked SHA-256.
- [ ] The app is signed by your team, the same as every earlier release, with hardened runtime and no `disable-library-validation`.
- [ ] The uploaded DMG has the SHA-256 that `release.sh` printed.
- [ ] Sparkle's security advisories were checked before this release: https://github.com/sparkle-project/Sparkle/security/advisories
