#!/bin/bash
# Builds Pitot in Release, signs it with Developer ID, notarizes and staples it, and packs it in a
# signed, notarized and stapled DMG. The steps and the one-time setup are in README.md next to this file.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Tools/release/release.sh --version X.Y.Z [--dry-run] [--skip-notarize] [--allow-dirty]

  --version X.Y.Z   Version of this release. It becomes both CFBundleShortVersionString and
                    CFBundleVersion, so it must be higher than every published version.
  --dry-run         Print each command without running it.
  --skip-notarize   Build, sign and package only. The DMG is signed but NOT notarized, and its
                    name ends in -unnotarized. Never publish it.
  --allow-dirty     Run even when the git tree has uncommitted or untracked changes.

Environment:
  PITOT_SIGN_IDENTITY   Signing identity. Default: the first "Developer ID Application" identity of
                        the team in App/project.yml.
  PITOT_NOTARY_PROFILE  notarytool keychain profile name. Needed unless --skip-notarize.
  PITOT_RELEASE_OUT     Output folder. Default: Tools/release/out.
EOF
}

die() {
  printf 'release.sh: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*" >&2
}

# Prints a command, then runs it unless this is a dry run. Output goes to stderr so callers can capture
# the command's own stdout.
run() {
  printf '+' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  if [[ $dry_run == 1 ]]; then
    return 0
  fi
  "$@"
}

plist_value() {
  plutil -extract "$2" raw -o - "$1/Contents/Info.plist"
}

version=""
dry_run=0
skip_notarize=0
allow_dirty=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version needs a value"
      version=$2
      shift 2
      ;;
    --dry-run) dry_run=1; shift ;;
    --skip-notarize) skip_notarize=1; shift ;;
    --allow-dirty) allow_dirty=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must look like 1.2.3, got '$version'"

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
app_dir="$repo_root/App"
out="${PITOT_RELEASE_OUT:-$script_dir/out}"
if [[ $skip_notarize == 1 ]]; then
  dmg_name="Pitot-$version-unnotarized.dmg"
else
  dmg_name="Pitot-$version.dmg"
fi
[[ ! -e "$out/$dmg_name" ]] || die "$out/$dmg_name already exists. A published version is never rebuilt: bump --version, or delete the file if it was never published."

command -v xcodegen >/dev/null || die "XcodeGen is missing. Install it with: brew install xcodegen"

git_status=$(git -C "$repo_root" status --porcelain) || die "$repo_root is not a git checkout. Release from a git checkout."
if [[ -n $git_status ]]; then
  if [[ $allow_dirty == 1 ]]; then
    note "warning: the git tree has uncommitted changes (--allow-dirty). Do not publish this build."
  else
    die "the git tree has uncommitted or untracked changes. Commit them first, or pass --allow-dirty for a test build."
  fi
fi

team=$(sed -n 's/^ *DEVELOPMENT_TEAM: *\([A-Z0-9]\{10\}\) *$/\1/p' "$app_dir/project.yml")
[[ $team =~ ^[A-Z0-9]{10}$ ]] || die "could not read exactly one DEVELOPMENT_TEAM from App/project.yml"

identity=${PITOT_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  identity=$(security find-identity -v -p codesigning |
    awk -F'"' -v suffix="($team)" '!found && index($2, "Developer ID Application: ") == 1 && substr($2, length($2) - 11) == suffix { print $2; found = 1 }') ||
    die "could not list the signing identities in the keychain"
fi
if [[ -z $identity ]]; then
  [[ $dry_run == 1 ]] || die "no \"Developer ID Application\" identity for team $team in the keychain. Set PITOT_SIGN_IDENTITY."
  identity="Developer ID Application: <missing> ($team)"
fi
note "signing identity: $identity"

notary_profile=${PITOT_NOTARY_PROFILE:-}
if [[ $skip_notarize == 0 && -z $notary_profile ]]; then
  message="PITOT_NOTARY_PROFILE is not set. Create a notarytool profile once. It asks for an app-specific
password: type it only at that prompt, never on a command line.
    xcrun notarytool store-credentials \"pitot-notary\" --apple-id \"<your Apple ID email>\" --team-id $team
Then run: PITOT_NOTARY_PROFILE=pitot-notary $0 --version $version
For a local build that is not notarized, pass --skip-notarize."
  [[ $dry_run == 1 ]] || die "$message"
  note "$message"
  notary_profile="<PITOT_NOTARY_PROFILE>"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/pitot-release.XXXXXX")
mount_point="$work/mnt"
is_mounted() {
  [[ -d $mount_point && $(stat -f %d "$mount_point") != $(stat -f %d "$work") ]]
}
cleanup() {
  if is_mounted; then
    hdiutil detach "$mount_point" -force >/dev/null || note "could not detach $mount_point"
  fi
  rm -rf "$work"
}
trap cleanup EXIT

archive="$work/Pitot.xcarchive"
app="$work/app/Pitot.app"
dmg_root="$work/dmg-root"
dmg="$work/$dmg_name"

# Checks that the code at $1 carries a Developer ID signature of $team with hardened runtime and a
# secure timestamp, as notarization requires.
check_code() {
  local info
  info=$(codesign -dvv "$1" 2>&1) || die "$1 is not signed"
  grep -q '^Authority=Developer ID Application: ' <<<"$info" || die "$1 is not signed with a Developer ID Application identity"
  grep -q "^TeamIdentifier=$team\$" <<<"$info" || die "$1 is not signed by team $team"
  grep -q '^Timestamp=' <<<"$info" || die "$1 has no secure timestamp"
  grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$info" || die "$1 does not have the hardened runtime flag"
}

# Every Mach-O file in the app, so a helper this script does not sign by name is still caught.
check_all_code() {
  local file count=0
  while IFS= read -r -d '' file; do
    if file -b "$file" | grep -q 'Mach-O'; then
      check_code "$file"
      count=$((count + 1))
    fi
  done < <(find "$1" -type f -perm -u+x -print0)
  [[ $count -gt 0 ]] || die "found no executable code in $1"
  note "$count executables are Developer ID signed by $team, with hardened runtime and a timestamp"
}

check_entitlements() {
  local entitlements forbidden
  entitlements=$(codesign -d --entitlements - --xml "$1" 2>/dev/null)
  for forbidden in get-task-allow disable-library-validation allow-unsigned-executable-memory allow-jit allow-dyld-environment-variables disable-executable-page-protection; do
    if grep -q "$forbidden" <<<"$entitlements"; then
      die "$1 has the entitlement $forbidden, which a release must not have"
    fi
  done
}

# Submits $1 and waits. Fails unless Apple answers Accepted, and saves Apple's log next to the output.
notarize() {
  local file=$1 label=$2
  local result="$work/notary-$label.json" status=0 state id log
  run xcrun notarytool submit "$file" --keychain-profile "$notary_profile" --wait --output-format json >"$result" || status=$?
  [[ $dry_run == 0 ]] || return 0
  state=$(plutil -extract status raw -o - "$result" 2>/dev/null) || state=""
  id=$(plutil -extract id raw -o - "$result" 2>/dev/null) || id=""
  if [[ $state != Accepted ]]; then
    printf 'Notarization of %s ended with status "%s" (notarytool exit code %s).\n' "$label" "${state:-unknown}" "$status" >&2
    if [[ -n $id ]]; then
      mkdir -p "$out"
      log="$out/notary-$label-$version-$id.json"
      if xcrun notarytool log "$id" --keychain-profile "$notary_profile" "$log"; then
        printf 'Apple log: %s\n' "$log" >&2
      fi
      printf 'Fetch the log again with: xcrun notarytool log %s --keychain-profile "$PITOT_NOTARY_PROFILE"\n' "$id" >&2
    fi
    die "notarization of $label failed"
  fi
  note "$label notarized (submission $id)"
}

# hdiutil detach can fail for a moment while macOS still reads a new volume, so it retries.
detach_mount() {
  for _ in 1 2 3; do
    run hdiutil detach "$mount_point" && return 0
    sleep 1
  done
  run hdiutil detach "$mount_point" -force
}

verify_dmg_contents() {
  run hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount_point" "$dmg"
  if [[ $dry_run == 0 ]]; then
    [[ -d "$mount_point/Pitot.app" ]] || die "the DMG has no Pitot.app"
    [[ -L "$mount_point/Applications" && $(readlink "$mount_point/Applications") == /Applications ]] ||
      die "the DMG has no Applications link to /Applications"
    [[ $(find "$mount_point" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l | tr -d ' ') == 2 ]] ||
      die "the DMG holds more than Pitot.app and the Applications link"
  fi
  run codesign --verify --deep --strict --verbose=2 "$mount_point/Pitot.app"
  if [[ $skip_notarize == 0 ]]; then
    run xcrun stapler validate "$mount_point/Pitot.app"
  fi
  detach_mount
}

if [[ $skip_notarize == 0 ]]; then
  note "checking the notarytool profile"
  run xcrun notarytool history --keychain-profile "$notary_profile" --output-format json >/dev/null ||
    die "notarytool cannot use the profile \"$notary_profile\". Create it with: xcrun notarytool store-credentials (see Tools/release/README.md)"
fi

note "building Pitot $version (Release) in $work"
run xcodegen generate --quiet --spec "$app_dir/project.yml"
run xcodebuild archive -quiet \
  -project "$app_dir/Pitot.xcodeproj" -scheme Pitot -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$work/DerivedData" -archivePath "$archive" \
  -onlyUsePackageVersionsFromResolvedFile \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$version" \
  CODE_SIGN_IDENTITY="$identity"
run mkdir -p "$work/app"
run ditto "$archive/Products/Applications/Pitot.app" "$app"

if [[ $dry_run == 0 ]]; then
  [[ $(plist_value "$app" CFBundleShortVersionString) == "$version" ]] || die "CFBundleShortVersionString is not $version"
  [[ $(plist_value "$app" CFBundleVersion) == "$version" ]] || die "CFBundleVersion is not $version"
  feed=$(plist_value "$app" SUFeedURL)
  public_key=$(plist_value "$app" SUPublicEDKey)
  problems=""
  if [[ ! $feed =~ ^https://[^/]+/ || $feed =~ ^https://[^/]*\.invalid/ ]]; then
    problems+=" SUFeedURL is a placeholder or not HTTPS ($feed)."
  fi
  if [[ -z $public_key ]]; then
    problems+=" SUPublicEDKey is empty."
  fi
  if [[ -n $problems ]]; then
    [[ $skip_notarize == 1 ]] || die "this build could never update itself:$problems Set PITOT_FEED_URL and PITOT_SPARKLE_PUBLIC_KEY in App/project.yml."
    note "warning:$problems The app cannot update itself. Fine for a local test build only."
  fi
fi

# Inside-out, never --deep: Sparkle's helpers, then the framework, then the app. Xcode signs only the
# framework and the app, which leaves the helpers ad-hoc signed, and notarization rejects that.
note "signing inside-out"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sparkle_version="$sparkle/Versions/B"
sign() {
  run codesign --force --sign "$identity" --options runtime --timestamp "$@"
}
[[ $dry_run == 1 || -d $sparkle_version ]] || die "$sparkle_version is missing. Check the embedded Sparkle layout."
if [[ $dry_run == 1 || -e "$sparkle_version/XPCServices/Installer.xpc" ]]; then
  sign "$sparkle_version/XPCServices/Installer.xpc"
fi
if [[ $dry_run == 1 || -e "$sparkle_version/XPCServices/Downloader.xpc" ]]; then
  sign --preserve-metadata=entitlements "$sparkle_version/XPCServices/Downloader.xpc"
fi
sign "$sparkle_version/Updater.app"
sign "$sparkle_version/Autoupdate"
sign "$sparkle"
sign --preserve-metadata=entitlements "$app"

note "verifying the app signature"
run codesign --verify --deep --strict --verbose=2 "$app"
if [[ $dry_run == 0 ]]; then
  check_all_code "$app"
  check_entitlements "$app"
fi

if [[ $skip_notarize == 0 ]]; then
  note "notarizing the app"
  run ditto -c -k --keepParent "$app" "$work/Pitot-$version.zip"
  notarize "$work/Pitot-$version.zip" app
  run xcrun stapler staple "$app"
  run xcrun stapler validate "$app"
fi

note "building the DMG"
run mkdir -p "$dmg_root"
run ditto "$app" "$dmg_root/Pitot.app"
run ln -s /Applications "$dmg_root/Applications"
run hdiutil create -volname Pitot -srcfolder "$dmg_root" -fs HFS+ -format UDZO -ov "$dmg"
run codesign --force --sign "$identity" --timestamp "$dmg"
run codesign --verify --strict --verbose=2 "$dmg"
verify_dmg_contents

if [[ $skip_notarize == 0 ]]; then
  note "notarizing the DMG"
  notarize "$dmg" dmg
  run xcrun stapler staple "$dmg"
  run xcrun stapler validate "$dmg"
fi

note "Gatekeeper assessment"
if [[ $skip_notarize == 0 ]]; then
  run spctl --assess --type execute -vv "$app"
  run spctl --assess --type open --context context:primary-signature -vv "$dmg"
else
  run spctl --assess --type execute -vv "$app" || note "rejected as expected: the app is not notarized"
  run spctl --assess --type open --context context:primary-signature -vv "$dmg" || note "rejected as expected: the DMG is not notarized"
fi

run mkdir -p "$out"
run mv "$dmg" "$out/$dmg_name"
if [[ $dry_run == 0 ]]; then
  printf '\nDMG:     %s\nSHA-256: %s\nSize:    %s bytes\n' \
    "$out/$dmg_name" "$(shasum -a 256 "$out/$dmg_name" | awk '{ print $1 }')" "$(stat -f %z "$out/$dmg_name")"
  if [[ $skip_notarize == 1 ]]; then
    printf 'NOT notarized. Do not publish this file.\n'
  fi
fi
