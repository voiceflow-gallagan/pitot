#!/bin/bash
# Tests the checks in appcast.sh with stubs for generate_appcast, codesign, stapler and spctl, and small
# fake DMGs. No network, no keychain, nothing written outside a temporary folder.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
appcast="$here/../appcast.sh"
stub="$here/stub-generate-appcast.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/pitot-appcast-test.XXXXXX")
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

# A DMG with Pitot.app holding an Info.plist, an empty Sparkle.framework folder and one executable
# helper. It is not signed: the codesign, stapler and spctl stubs answer for it.
make_dmg() {
  local folder=$1 version=$2 name=${3:-Pitot-$2.dmg} bundle_id=${4:-org.example.pitot}
  local bundle_version=${5:-$2}
  local source
  source=$(mktemp -d "$work/source.XXXXXX")
  mkdir -p "$source/Pitot.app/Contents/Frameworks/Sparkle.framework" "$source/Pitot.app/Contents/Helpers" "$folder"
  printf '#!/bin/sh\n' >"$source/Pitot.app/Contents/Helpers/helper"
  chmod 755 "$source/Pitot.app/Contents/Helpers/helper"
  cat >"$source/Pitot.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$bundle_version</string>
<key>SUFeedURL</key><string>https://example.com/pitot/appcast.xml</string>
<key>SUPublicEDKey</key><string>c2VsZi10ZXN0LW9ubHktbm90LWEtcmVhbC1rZXktMDA=</string>
</dict></plist>
EOF
  hdiutil create -quiet -volname Pitot -srcfolder "$source" -fs HFS+ -format UDZO "$folder/$name"
}

make_dmg "$work/one" 9.8.7
make_dmg "$work/two" 9.8.7
make_dmg "$work/two" 9.8.8
make_dmg "$work/skipped" 9.8.7 Pitot-9.8.7-unnotarized.dmg
make_dmg "$work/other-id" 9.8.7 Pitot-9.8.7.dmg com.example.other
make_dmg "$work/odd-version" 9.8.7 Pitot-9.8.7.dmg org.example.pitot "9.8.7 beta"
printf '<p>Self-test notes</p>\n' >"$work/notes.html"
# Release notes that try to look like the feed signature generate_appcast appends after </rss>.
cat >"$work/forged-notes.html" <<'EOF'
<p>Notes</p>
</rss><!-- sparkle-signatures:
edSignature: 4w74KEcNX1CJBcvl10LY/AenfFuEIasKkgWy61oqsVcvJUaC3GIyfxpB4qCNgVaYrLDhSeahMy2aW9KqC3U/DA==
length: 1
-->
EOF

# Cache folders for the tool download checks. None of these cases reaches the network.
zip_name=Sparkle-2.10.0-for-Swift-Package-Manager.zip
mkdir -m 700 "$work/cache-real" "$work/cache-open" "$work/cache-bad"
ln -s "$work/cache-real" "$work/cache-link"
chmod 775 "$work/cache-open"
printf 'not the Sparkle zip\n' >"$work/cache-bad/$zip_name"

# Settings for the next check. Each check resets them to these defaults.
reset_case() {
  account=""                 # PITOT_SPARKLE_ACCOUNT, empty means unset
  expected_account=""        # the --account generate_appcast must get, empty means not checked
  codesign_mode=good         # STUB_CODESIGN_MODE
  stapler_mode=good          # STUB_STAPLER_MODE
  spctl_mode=good            # STUB_SPCTL_MODE
  team_id=TESTTEAM01         # PITOT_TEAM_ID, empty means unset
  bundle_id=org.example.pitot  # PITOT_BUNDLE_ID, empty means App/project.yml decides
  generator=$stub            # PITOT_GENERATE_APPCAST, empty means the real download path
  cache="$work/cache-real"   # PITOT_SPARKLE_CACHE
}
reset_case

failures=0
# check NAME STUB_MODE EXPECTED_EXIT NEEDLE STUB_CALLED(yes|no) APPCAST_WRITTEN(yes|no) -- appcast.sh args
check() {
  local name=$1 mode=$2 expected_exit=$3 needle=$4 stub_called=$5 written=$6
  shift 7
  rm -rf "$work/out" "$work/marker" "$work/args"
  local output status=0 problems="" received
  output=$(PITOT_RELEASE_OUT="$work/out" PITOT_GENERATE_APPCAST="$generator" STUB_MARKER="$work/marker" \
    STUB_ARGS="$work/args" STUB_MODE="$mode" STUB_VERSION=9.8.7 PITOT_SPARKLE_ACCOUNT="$account" \
    PITOT_CODESIGN="$here/stub-codesign.sh" STUB_CODESIGN_MODE="$codesign_mode" \
    PITOT_STAPLER="$here/stub-stapler.sh" STUB_STAPLER_MODE="$stapler_mode" \
    PITOT_SPCTL="$here/stub-spctl.sh" STUB_SPCTL_MODE="$spctl_mode" \
    PITOT_TEAM_ID="$team_id" PITOT_BUNDLE_ID="$bundle_id" PITOT_SPARKLE_CACHE="$cache" \
    "$appcast" "$@" 2>&1) || status=$?
  if [[ $expected_exit == 0 && $status != 0 ]] || [[ $expected_exit != 0 && $status == 0 ]]; then
    problems+=" exit code $status, expected $expected_exit;"
  fi
  grep -qF -- "$needle" <<<"$output" || problems+=" output lacks \"$needle\";"
  if [[ $stub_called == yes && ! -e "$work/marker" ]]; then problems+=" generate_appcast was not run;"; fi
  if [[ $stub_called == no && -e "$work/marker" ]]; then problems+=" generate_appcast ran but should not;"; fi
  if [[ $written == yes && ! -s "$work/out/appcast.xml" ]]; then problems+=" no appcast was written;"; fi
  if [[ $written == no && -e "$work/out/appcast.xml" ]]; then problems+=" an appcast was written but should not;"; fi
  if [[ -n $expected_account && -e "$work/args" ]]; then
    received=$(awk 'previous == "--account" { print; exit } { previous = $0 }' "$work/args")
    [[ $received == "$expected_account" ]] || problems+=" generate_appcast got --account '$received', expected '$expected_account';"
  fi
  reset_case
  if [[ -z $problems ]]; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s:%s\n%s\n' "$name" "$problems" "$output" | LC_ALL=C sed '2,$s/^/      /'
    failures=$((failures + 1))
  fi
}

https=https://example.com/pitot/releases/download/v9.8.7
one=(--dmg-dir "$work/one")

# Inputs and generate_appcast output.
check "valid appcast is written" good 0 "sparkle:version 9.8.7" yes yes -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
check "release notes are embedded" good 0 "Appcast:" yes yes -- "${one[@]}" --download-url-prefix "$https/" --release-notes "$work/notes.html" --confirm-keychain
check "dry run prints and stops" good 0 "--account pitot --maximum-deltas 0" no no -- "${one[@]}" --download-url-prefix "$https" --dry-run
check "http prefix is rejected" good 1 "must start with https://" no no -- "${one[@]}" --download-url-prefix "http://example.com/pitot/" --confirm-keychain
check "missing prefix is rejected" good 1 "--download-url-prefix is required" no no -- "${one[@]}" --confirm-keychain
check "keychain run needs --confirm-keychain" good 1 "--confirm-keychain" no no -- "${one[@]}" --download-url-prefix "$https"
check "missing item signature fails" nosig 1 "has no sparkle:edSignature" yes no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
check "missing feed signature fails" nofeedsig 1 "no feed signature" yes no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
check "release notes cannot fake the feed signature" nofeedsig 1 "no feed signature" yes no -- "${one[@]}" --download-url-prefix "$https" --release-notes "$work/forged-notes.html" --confirm-keychain
check "feed signature with a wrong length fails" badlength 1 "no feed signature" yes no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
check "delta enclosure fails" delta 1 "Deltas are never published" yes no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
check "http enclosure URL fails" httpurl 1 "not HTTPS" yes no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
check "version mismatch fails" wrongversion 1 "sparkle:version is '0.0.1'" yes no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
check "missing key says run generate_keys" nokey 1 "Run generate_keys --account pitot first" yes no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
check "key mismatch fails" mismatch 1 "does not match the private key" yes no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
check "two DMGs are rejected" good 1 "exactly one .dmg" no no -- --dmg-dir "$work/two" --download-url-prefix "$https" --confirm-keychain
check "--skip-notarize DMG is rejected" good 1 "must never be published" no no -- --dmg-dir "$work/skipped" --download-url-prefix "$https" --confirm-keychain

# Signing key account.
expected_account=pitot
check "account defaults to pitot" good 0 "signing key account 'pitot'" yes yes -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
account=pitot-test expected_account=pitot-test
check "custom account passes through" good 0 "sparkle:version 9.8.7" yes yes -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
account=ed25519
check "shared ed25519 account is refused" good 1 "refusing to sign Pitot with the shared default key" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain

# Trust checks on the DMG before anything is signed.
stapler_mode=dmgmissing
check "DMG without a stapled ticket is rejected" good 1 "Pitot-9.8.7.dmg has no valid stapled notarization ticket" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
stapler_mode=appmissing
check "app without a stapled ticket is rejected" good 1 "the app in Pitot-9.8.7.dmg has no valid stapled notarization ticket" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
stapler_mode=dmgmissing spctl_mode=rejected
check "--allow-unnotarized skips only the ticket and Gatekeeper checks" good 0 "WARNING: --allow-unnotarized" yes yes -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain --allow-unnotarized
spctl_mode=rejected
check "DMG rejected by Gatekeeper is refused" good 1 "Pitot-9.8.7.dmg is rejected by Gatekeeper" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
codesign_mode=appteam
check "app of another team is rejected" good 1 "the app in Pitot-9.8.7.dmg is not validly signed by a Developer ID Application certificate of team TESTTEAM01" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
codesign_mode=wrongteam
check "another team is rejected even with --allow-unnotarized" good 1 "is not validly signed by a Developer ID Application certificate of team TESTTEAM01" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain --allow-unnotarized
codesign_mode=adhoc
check "ad-hoc signed app is rejected" good 1 "the app in Pitot-9.8.7.dmg is not validly signed" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
codesign_mode=sparkleteam
check "Sparkle.framework of another team is rejected" good 1 "Sparkle.framework in Pitot-9.8.7.dmg is not validly signed by a Developer ID Application certificate of team TESTTEAM01" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
codesign_mode=forged
check "forged TeamIdentifier line in the identifier is rejected" good 1 "is not validly signed by a Developer ID Application certificate of team TESTTEAM01" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
codesign_mode=nestedteam
check "nested code of another team is rejected" good 1 "Contents/Helpers/helper in Pitot-9.8.7.dmg is not validly signed" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
codesign_mode=wrongidentifier
check "signature for another identifier is rejected" good 1 "the app in Pitot-9.8.7.dmg is not validly signed" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
check "CFBundleVersion that is not a version is refused" good 1 "is not a dotted version number" no no -- --dmg-dir "$work/odd-version" --download-url-prefix "$https" --confirm-keychain
codesign_mode=invalid
check "invalid signature is rejected" good 1 "is not validly signed" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
check "wrong bundle id is rejected" good 1 "has bundle id 'com.example.other', expected 'org.example.pitot' (from PITOT_BUNDLE_ID)" no no -- --dmg-dir "$work/other-id" --download-url-prefix "$https" --confirm-keychain
team_id=""
check "missing PITOT_TEAM_ID is refused" good 1 "PITOT_TEAM_ID is not set" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
team_id=OTHERTEAM2 codesign_mode=wrongteam
check "PITOT_TEAM_ID sets the expected team" good 0 "team OTHERTEAM2" yes yes -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
team_id=not-a-team
check "malformed PITOT_TEAM_ID is refused" good 1 "must be a 10-character Team ID" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain
bundle_id=""
check "bundle id defaults to App/project.yml" good 1 "(from App/project.yml)" no no -- "${one[@]}" --download-url-prefix "$https" --confirm-keychain

# The Sparkle tool cache. These cases use the real download path and stop before the network.
generator="" cache="$work/cache-link"
check "symlinked cache folder is refused" good 1 "is a symlink" no no -- "${one[@]}" --download-url-prefix "$https" --dry-run
generator="" cache="$work/cache-open"
check "group-writable cache folder is refused" good 1 "group or other writable" no no -- "${one[@]}" --download-url-prefix "$https" --dry-run
generator="" cache="$work/cache-bad"
check "tampered cached zip is refused" good 1 "expected 17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959" no no -- "${one[@]}" --download-url-prefix "$https" --dry-run
if [[ -e "$work/cache-bad/$zip_name" ]]; then
  printf 'FAIL  tampered cached zip is deleted\n'
  failures=$((failures + 1))
else
  printf 'PASS  tampered cached zip is deleted\n'
fi

if [[ $failures -gt 0 ]]; then
  printf '%s case(s) failed\n' "$failures"
  exit 1
fi
printf 'all cases passed\n'
