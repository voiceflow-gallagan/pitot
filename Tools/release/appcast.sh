#!/bin/bash
# Writes the Sparkle appcast for a notarized Pitot DMG with generate_appcast from the pinned Sparkle zip,
# then checks the result. The EdDSA private key stays in the login keychain: generate_appcast reads it
# there itself, and this script never passes or reads the key.
set -euo pipefail

readonly sparkle_version=2.10.0
readonly sparkle_zip_url="https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-for-Swift-Package-Manager.zip"
readonly sparkle_zip_sha256=17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959
readonly sparkle_zip_name="Sparkle-$sparkle_version-for-Swift-Package-Manager.zip"

usage() {
  cat <<'EOF'
Usage: Tools/release/appcast.sh --dmg-dir DIR --download-url-prefix https://... [--release-notes FILE]
                                (--confirm-keychain | --dry-run) [--allow-unnotarized]

  --dmg-dir DIR              Folder with exactly one notarized Pitot DMG. An appcast.xml in the same
                             folder is the starting point, so earlier releases stay in the feed.
  --download-url-prefix URL  HTTPS folder the DMG will be downloaded from, for example
                             https://github.com/OWNER/REPO/releases/download/v1.2.3/
  --release-notes FILE       Optional .html, .md or .txt notes, embedded in the appcast.
  --confirm-keychain         Needed for a real run. generate_appcast reads the EdDSA private key from
                             the login keychain, and macOS may ask you to allow that.
  --dry-run                  Check the inputs and the tool, print the generate_appcast command, stop.
  --allow-unnotarized        Skip the stapled-ticket checks only. The Developer ID and Team ID checks
                             still run. Tests only: never publish the result.

Environment:
  PITOT_TEAM_ID           Required. Team ID of your Developer ID certificate. The app and Sparkle.framework
                          must be signed by it, because installed copies reject an update from another team.
  PITOT_BUNDLE_ID         Bundle id the app must have. Default: PRODUCT_BUNDLE_IDENTIFIER of the Pitot
                          target in App/project.yml.
  PITOT_SPARKLE_ACCOUNT   Keychain account of Pitot's EdDSA key. Default: pitot. Sparkle's shared default
                          account ed25519 is refused, because other apps may sign with it.
  PITOT_SPARKLE_CACHE     Private folder for the Sparkle zip. Default: $TMPDIR/pitot-release, or
                          ~/Library/Caches/pitot-release when TMPDIR is unset or /tmp.
  PITOT_GENERATE_APPCAST  generate_appcast to run instead of the one from the Sparkle 2.10.0 zip (tests).
  PITOT_CODESIGN          codesign to run instead of /usr/bin/codesign (tests).
  PITOT_STAPLER           Program to run instead of `xcrun stapler` (tests).
  PITOT_SPCTL             spctl to run instead of /usr/sbin/spctl (tests).
  PITOT_RELEASE_OUT       Output folder. Default: Tools/release/out.
EOF
}

die() {
  printf 'appcast.sh: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*" >&2
}

run() {
  printf '+' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  if [[ $dry_run == 1 ]]; then
    return 0
  fi
  "$@"
}

run_codesign() {
  "${PITOT_CODESIGN:-/usr/bin/codesign}" "$@"
}

run_stapler() {
  if [[ -n ${PITOT_STAPLER:-} ]]; then
    "$PITOT_STAPLER" "$@"
  else
    xcrun stapler "$@"
  fi
}

run_spctl() {
  "${PITOT_SPCTL:-/usr/sbin/spctl}" "$@"
}

# Prints text that came from an artifact as one line of printable characters, at most 300 of them, so
# it cannot add lines or terminal escapes to the output.
one_line() {
  printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' ' ' | cut -c1-300
}

# Fails unless the code at $1 is valid and satisfies the code requirement $3, as evaluated by codesign
# itself. Options after $3, such as --deep, go to codesign. No decision reads codesign's text output.
check_requirement() {
  local path=$1 label=$2 requirement=$3 output
  shift 3
  if ! output=$(run_codesign --verify --strict "$@" -R "=$requirement" "$path" 2>&1); then
    die "$label is not validly signed by a Developer ID Application certificate of team $expected_team. codesign: $(one_line "$output")"
  fi
}

# hdiutil detach can fail for a moment while macOS still reads a new volume, so it retries.
detach_mount() {
  for _ in 1 2 3; do
    hdiutil detach "$mount_point" >/dev/null 2>&1 && return 0
    sleep 1
  done
  hdiutil detach "$mount_point" -force >/dev/null || die "could not detach $mount_point"
}

# Prints the PRODUCT_BUNDLE_IDENTIFIER of the Pitot target in the XcodeGen spec $1.
spec_bundle_id() {
  awk '
    /^targets:/ { in_targets = 1; next }
    /^[^[:space:]#]/ { in_targets = 0 }
    in_targets && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { target = $1; sub(/:$/, "", target) }
    in_targets && target == "Pitot" && $1 == "PRODUCT_BUNDLE_IDENTIFIER:" { value = $2; gsub(/"/, "", value); print value; exit }
  ' "$1"
}

# Creates the cache folder with mode 700 when it is missing, and refuses one that is a symlink, belongs
# to another user, or that other users can write to.
prepare_cache() {
  local owner mode
  [[ ! -L $cache ]] || die "the cache folder $cache is a symlink. Refusing to follow it."
  if [[ ! -e $cache ]]; then
    mkdir -m 700 "$cache" || die "could not create the cache folder $cache"
  fi
  [[ -d $cache ]] || die "the cache path $cache is not a folder"
  read -r owner mode <<<"$(stat -f '%u %Lp' "$cache")"
  [[ $owner == "$(id -u)" ]] || die "the cache folder $cache belongs to user $owner, not to you. Refusing to use it."
  (((8#$mode & 8#022) == 0)) || die "the cache folder $cache is group or other writable (mode $mode). Refusing to use it."
}

dmg_dir=""
prefix=""
notes=""
confirm_keychain=0
dry_run=0
allow_unnotarized=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg-dir | --download-url-prefix | --release-notes)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case "$1" in
        --dmg-dir) dmg_dir=$2 ;;
        --download-url-prefix) prefix=$2 ;;
        --release-notes) notes=$2 ;;
      esac
      shift 2
      ;;
    --confirm-keychain) confirm_keychain=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --allow-unnotarized) allow_unnotarized=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

account=${PITOT_SPARKLE_ACCOUNT:-pitot}
[[ $account != ed25519 ]] ||
  die "refusing to sign Pitot with the shared default key (account ed25519). Pitot has its own account: unset PITOT_SPARKLE_ACCOUNT to use 'pitot'."
[[ $account =~ ^[A-Za-z0-9._-]+$ ]] || die "PITOT_SPARKLE_ACCOUNT may use only letters, digits and . _ -, got '$account'"

[[ -n $prefix ]] || die "--download-url-prefix is required"
[[ $prefix == https://* ]] || die "--download-url-prefix must start with https://, got '$prefix'. Updates are never served over plain HTTP."
[[ $prefix =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%+-]*)*$ ]] ||
  die "--download-url-prefix has characters this script does not accept: '$prefix'"
[[ $prefix == */ ]] || prefix="$prefix/"

[[ -n $dmg_dir ]] || die "--dmg-dir is required"
[[ -d $dmg_dir ]] || die "$dmg_dir is not a folder"
dmgs=()
while IFS= read -r -d '' file; do
  dmgs+=("$file")
done < <(find "$dmg_dir" -mindepth 1 -maxdepth 1 -name '*.dmg' -print0)
[[ ${#dmgs[@]} == 1 ]] || die "$dmg_dir must hold exactly one .dmg, found ${#dmgs[@]}. Use a folder with only the DMG of this release."
dmg=${dmgs[0]}
dmg_name=$(basename "$dmg")
[[ $dmg_name =~ ^[A-Za-z0-9._+-]+\.dmg$ ]] || die "the DMG name '$dmg_name' must use only letters, digits and . _ + -"
[[ $dmg_name != *-unnotarized.dmg || $allow_unnotarized == 1 ]] || die "$dmg_name was built with --skip-notarize and must never be published"

notes_ext=""
if [[ -n $notes ]]; then
  [[ -f $notes ]] || die "release notes file $notes does not exist"
  notes_ext=${notes##*.}
  case "$notes_ext" in
    html | md | txt) ;;
    *) die "release notes must be a .html, .md or .txt file" ;;
  esac
fi

if [[ $dry_run == 0 && $confirm_keychain == 0 ]]; then
  die "refusing to run without --confirm-keychain. generate_appcast reads the EdDSA private key from your login keychain, and macOS may ask you to allow it. Pass --dry-run to only check the inputs."
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
out="${PITOT_RELEASE_OUT:-$script_dir/out}"

work=$(mktemp -d "${TMPDIR:-/tmp}/pitot-appcast.XXXXXX")
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

# Sparkle installs an update only when its Apple signature has the installed app's Team ID, so the
# key never signs a DMG from another team.
expected_team=${PITOT_TEAM_ID:-}
[[ -n $expected_team ]] ||
  die "PITOT_TEAM_ID is not set. Set it to the 10-character Team ID of your Developer ID certificate, the DEVELOPMENT_TEAM in App/project.yml."
[[ $expected_team =~ ^[A-Z0-9]{10}$ ]] || die "PITOT_TEAM_ID must be a 10-character Team ID, got '$expected_team'"
if [[ -n ${PITOT_BUNDLE_ID:-} ]]; then
  expected_bundle_id=$PITOT_BUNDLE_ID
  bundle_id_source=PITOT_BUNDLE_ID
else
  expected_bundle_id=$(spec_bundle_id "$script_dir/../../App/project.yml") || expected_bundle_id=""
  bundle_id_source=App/project.yml
fi
[[ $expected_bundle_id =~ ^[A-Za-z0-9.-]+$ ]] ||
  die "could not read the bundle id of the Pitot target from App/project.yml. Set PITOT_BUNDLE_ID."
if [[ -n ${PITOT_CODESIGN:-} || -n ${PITOT_STAPLER:-} || -n ${PITOT_SPCTL:-} ]]; then
  note "WARNING: PITOT_CODESIGN, PITOT_STAPLER or PITOT_SPCTL replaces the real signature checks. Tests only."
fi
# A Developer ID Application certificate of the expected team, issued under Apple's root:
# 1.2.840.113635.100.6.2.6 marks the Developer ID intermediate certificate and 1.2.840.113635.100.6.1.13
# the Developer ID Application leaf. Only the two values checked by the patterns above go into it.
developer_id_requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$expected_team\""
app_requirement="$developer_id_requirement and identifier \"$expected_bundle_id\""

# Every check and generate_appcast use this private copy, so the DMG cannot change between the checks
# and the signature. generate_appcast also writes into this folder (appcast, deltas, old_updates/).
feed="$work/feed"
mkdir "$feed"
cp "$dmg" "$feed/$dmg_name"
dmg="$feed/$dmg_name"

note "checking $dmg_name"
check_requirement "$dmg" "$dmg_name" "$developer_id_requirement"
if [[ $allow_unnotarized == 0 ]]; then
  run_stapler validate "$dmg" >/dev/null ||
    die "$dmg_name has no valid stapled notarization ticket. Run release.sh without --skip-notarize."
fi
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount_point" "$dmg" >/dev/null || die "could not mount $dmg_name"
app="$mount_point/Pitot.app"
[[ -d $app ]] || die "$dmg_name holds no Pitot.app"
plist="$app/Contents/Info.plist"
bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$plist") || die "the app has no CFBundleIdentifier"
[[ $bundle_id == "$expected_bundle_id" ]] ||
  die "the app in $dmg_name has bundle id '$(one_line "$bundle_id")', expected '$expected_bundle_id' (from $bundle_id_source)"
bundle_version=$(plutil -extract CFBundleVersion raw -o - "$plist") || die "the app has no CFBundleVersion"
short_version=$(plutil -extract CFBundleShortVersionString raw -o - "$plist") || die "the app has no CFBundleShortVersionString"
[[ $bundle_version =~ ^[0-9]+(\.[0-9]+)*$ ]] ||
  die "the app's CFBundleVersion '$(one_line "$bundle_version")' is not a dotted version number"
[[ $short_version =~ ^[0-9]+(\.[0-9]+)*$ ]] ||
  die "the app's CFBundleShortVersionString '$(one_line "$short_version")' is not a dotted version number"
public_key=$(plutil -extract SUPublicEDKey raw -o - "$plist" 2>/dev/null) || public_key=""
feed_url=$(plutil -extract SUFeedURL raw -o - "$plist" 2>/dev/null) || feed_url=""
[[ -n $public_key ]] || die "the app in $dmg_name has an empty SUPublicEDKey, so it could not check any update"
[[ $feed_url =~ ^https://[^/]+/ && ! $feed_url =~ ^https://[^/]*\.invalid/ ]] ||
  die "the app in $dmg_name has a placeholder or non-HTTPS SUFeedURL ($(one_line "$feed_url"))"
check_requirement "$app" "the app in $dmg_name" "$app_requirement" --deep
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || die "the app in $dmg_name has no Sparkle.framework"
check_requirement "$app/Contents/Frameworks/Sparkle.framework" "Sparkle.framework in $dmg_name" "$developer_id_requirement" --deep
# --deep checks that nested code is valid, but -R applies to the outer code only. So every executable
# file, such as Sparkle's Autoupdate and the main programs of its XPC services, is checked on its own.
while IFS= read -r -d '' file; do
  check_requirement "$file" "$(one_line "${file#"$app"/}") in $dmg_name" "$developer_id_requirement"
done < <(find "$app" -type f -perm -u+x -print0)
if [[ $allow_unnotarized == 0 ]]; then
  run_stapler validate "$app" >/dev/null || die "the app in $dmg_name has no valid stapled notarization ticket"
  run_spctl --assess --type execute -vv "$app" >/dev/null 2>&1 || die "the app in $dmg_name is rejected by Gatekeeper (spctl)"
  run_spctl --assess --type open --context context:primary-signature -vv "$dmg" >/dev/null 2>&1 ||
    die "$dmg_name is rejected by Gatekeeper (spctl)"
else
  note "WARNING: --allow-unnotarized: the stapled tickets and Gatekeeper were not checked. Never publish this appcast."
fi
detach_mount
note "$bundle_id $short_version, CFBundleVersion $bundle_version, team $expected_team, signing key account '$account'"

if [[ -n ${PITOT_GENERATE_APPCAST:-} ]]; then
  generator=$PITOT_GENERATE_APPCAST
  [[ -x $generator ]] || die "PITOT_GENERATE_APPCAST=$generator is not executable"
  note "using generate_appcast from PITOT_GENERATE_APPCAST: $generator"
else
  if [[ -n ${PITOT_SPARKLE_CACHE:-} ]]; then
    cache=$PITOT_SPARKLE_CACHE
  elif [[ -n ${TMPDIR:-} && ${TMPDIR%/} != /tmp && ${TMPDIR%/} != /private/tmp ]]; then
    cache="${TMPDIR%/}/pitot-release"
  else
    cache="$HOME/Library/Caches/pitot-release"
  fi
  prepare_cache
  # The zip is hashed and unpacked only as a copy inside the private $work folder, so nothing can
  # replace it between the check and the use.
  cached_zip="$cache/$sparkle_zip_name"
  private_zip="$work/$sparkle_zip_name"
  [[ ! -L $cached_zip ]] || die "$cached_zip is a symlink. Refusing to use it."
  from_cache=0
  if [[ -f $cached_zip ]]; then
    cp "$cached_zip" "$private_zip"
    from_cache=1
  else
    note "downloading the Sparkle $sparkle_version tools"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$private_zip" "$sparkle_zip_url"
  fi
  actual_sha256=$(shasum -a 256 "$private_zip" | awk '{ print $1 }')
  if [[ $actual_sha256 != "$sparkle_zip_sha256" ]]; then
    if [[ $from_cache == 1 ]]; then
      rm -f "$cached_zip"
    fi
    die "the Sparkle zip has SHA-256 $actual_sha256, expected $sparkle_zip_sha256. It was deleted. Do not continue until you know why."
  fi
  note "Sparkle $sparkle_version zip SHA-256 verified"
  if [[ $from_cache == 0 ]]; then
    cp "$private_zip" "$cached_zip.part"
    mv -f "$cached_zip.part" "$cached_zip"
  fi
  unzip -q "$private_zip" 'bin/generate_appcast' -d "$work/sparkle"
  generator="$work/sparkle/bin/generate_appcast"
  [[ ! -L $generator && -f $generator ]] || die "the generate_appcast in the Sparkle zip is not a regular file"
  run_codesign --verify --strict "$generator" >/dev/null 2>&1 || die "the generate_appcast in the Sparkle zip fails codesign --verify"
  note "generate_appcast: signature valid (Sparkle signs its tools ad-hoc), SHA-256 $(shasum -a 256 "$generator" | awk '{ print $1 }')"
fi

if [[ -f "$dmg_dir/appcast.xml" ]]; then
  cp -p "$dmg_dir/appcast.xml" "$feed/appcast.xml"
  note "starting from the existing $dmg_dir/appcast.xml"
fi
args=(--account "$account" --maximum-deltas 0 --download-url-prefix "$prefix")
if [[ -n $notes ]]; then
  cp "$notes" "$feed/${dmg_name%.dmg}.$notes_ext"
  args+=(--embed-release-notes)
fi
args+=(-o "$feed/appcast.xml" "$feed")

note "generating the appcast"
if [[ $dry_run == 1 ]]; then
  run "$generator" "${args[@]}"
  note "dry run: stopped before generate_appcast. Nothing was signed or written."
  exit 0
fi
status=0
"$generator" "${args[@]}" >"$work/generate.log" 2>&1 || status=$?
# The log can quote names from the DMG, so control characters are removed before printing it. The two
# checks below can only add a failure, never pass a run.
LC_ALL=C tr -cd '[:print:]\n' <"$work/generate.log" >&2
if grep -q -E 'not found in the Keychain|Unable to load EdDSA private key|Please run the generate_keys tool' "$work/generate.log"; then
  die "no EdDSA private key for account '$account' in the login keychain. Run generate_keys --account $account first (Tools/release/README.md, one-time setup)."
fi
if grep -q 'does not match key EdDSA in the Keychain' "$work/generate.log"; then
  die "the SUPublicEDKey in the app does not match the private key in the keychain. Do not publish."
fi
[[ $status == 0 ]] || die "generate_appcast failed with exit code $status"

xml="$feed/appcast.xml"
dmg_url="$prefix$dmg_name"
xpath() {
  xmllint --xpath "$1" "$xml"
}
note "checking the appcast"
[[ -s $xml ]] || die "generate_appcast wrote no appcast"
xmllint --noout "$xml" || die "the appcast is not well-formed XML"
[[ $(xpath 'count(//item)') -ge 1 ]] || die "the appcast has no item"
[[ $(xpath "count(//@url[not(starts-with(normalize-space(.), 'https://'))]) + count(//@href[not(starts-with(normalize-space(.), 'https://'))])") == 0 ]] ||
  die "the appcast has a URL that is not HTTPS"
[[ $(xpath "count(//*[local-name()='link' or local-name()='releaseNotesLink' or local-name()='fullReleaseNotesLink'][normalize-space(.) != '' and not(starts-with(normalize-space(.), 'https://'))])") == 0 ]] ||
  die "the appcast has a link that is not HTTPS"
[[ $(xpath "count(//enclosure[not(@*[local-name()='edSignature' and normalize-space(.) != ''])])") == 0 ]] ||
  die "an enclosure has no sparkle:edSignature"
[[ $(xpath "count(//*[local-name()='deltas']) + count(//enclosure[contains(@url, '.delta')])") == 0 ]] ||
  die "the appcast lists a .delta update. Deltas are never published"
[[ -z $(find "$feed" -name '*.delta') ]] || die "generate_appcast created .delta files. Deltas are never published"
# generate_appcast signs the feed by appending a comment after </rss>: it is the last node of the
# document, and its length field is the number of signed bytes before it. Text inside the feed, such as
# embedded release notes, can never be a top-level node, so it cannot stand in for this comment.
feed_signature=$(xpath 'string(/node()[last()][self::comment()])') || feed_signature=""
feed_signature_pattern=$'^ sparkle-signatures:\nedSignature: [A-Za-z0-9+/]+=*\nlength: ([0-9]+)$'
signature_offset=$(LC_ALL=C grep -b -o '<!-- sparkle-signatures:' "$xml" | tail -n 1 | cut -d: -f1) || signature_offset=""
[[ $feed_signature =~ $feed_signature_pattern && ${BASH_REMATCH[1]} == "$signature_offset" ]] ||
  die "the appcast has no feed signature at its end, or its length is wrong, and the app requires one (SURequireSignedFeed)"
[[ $(xpath "count(//item[enclosure/@url='$dmg_url'])") == 1 ]] || die "the appcast has no single item for $dmg_url"
item_version=$(xpath "string(//item[enclosure/@url='$dmg_url']/*[local-name()='version'])")
if [[ -z $item_version ]]; then
  item_version=$(xpath "string(//item/enclosure[@url='$dmg_url']/@*[local-name()='version'])")
fi
[[ $item_version == "$bundle_version" ]] ||
  die "sparkle:version is '$(one_line "$item_version")' but the app's CFBundleVersion is '$bundle_version'"

mkdir -p "$out"
cp "$xml" "$out/appcast.xml"
printf '\nAppcast: %s\nItem:    %s, sparkle:version %s\nSHA-256: %s\n' \
  "$out/appcast.xml" "$dmg_url" "$item_version" "$(shasum -a 256 "$out/appcast.xml" | awk '{ print $1 }')"
