#!/bin/bash
# Stands in for codesign in appcast-selftest.sh. It evaluates a -R requirement the way the real
# codesign would for a code signature described by STUB_CODESIGN_MODE:
#   good         Developer ID of team TESTTEAM01 on everything
#   wrongteam    Developer ID of team OTHERTEAM2 on everything
#   appteam      only Pitot.app itself is signed by team OTHERTEAM2
#   sparkleteam  Sparkle.framework and the code in it are signed by team ZZZZZZZZZZ
#   nestedteam   code under Contents/Helpers is signed by team ZZZZZZZZZZ
#   wrongidentifier  the app's signature has the identifier com.example.signed
#   adhoc        everything except the DMG is ad-hoc signed
#   forged       team OTHERTEAM2, with an identifier that holds a newline and fake
#                "TeamIdentifier=TESTTEAM01" and "Authority=Developer ID Application" lines
#   invalid      every --verify fails
set -euo pipefail

mode=${STUB_CODESIGN_MODE:-good}
verify=0
display=0
requirement=""
while [[ $# -gt 1 ]]; do
  case "$1" in
    --verify) verify=1; shift ;;
    --strict | --deep) shift ;;
    -R) requirement=$2; shift 2 ;;
    -dv | -dvv) display=1; shift ;;
    *) echo "stub codesign: unexpected argument $1" >&2; exit 2 ;;
  esac
done
path=$1

team=TESTTEAM01
adhoc=0
identifier=$(basename "$path")
if [[ -f "$path/Contents/Info.plist" ]]; then
  identifier=$(plutil -extract CFBundleIdentifier raw -o - "$path/Contents/Info.plist")
fi
case "$mode" in
  good | invalid) ;;
  wrongteam | forged) team=OTHERTEAM2 ;;
  appteam) [[ $path != */Pitot.app ]] || team=OTHERTEAM2 ;;
  sparkleteam) [[ $path != */Sparkle.framework* ]] || team=ZZZZZZZZZZ ;;
  nestedteam) [[ $path != */Contents/Helpers/* ]] || team=ZZZZZZZZZZ ;;
  wrongidentifier) [[ $path != */Pitot.app ]] || identifier=com.example.signed ;;
  adhoc) [[ $path == *.dmg ]] || adhoc=1 ;;
  *) echo "stub codesign: unknown STUB_CODESIGN_MODE $mode" >&2; exit 2 ;;
esac
if [[ $mode == forged ]]; then
  identifier=$'org.example.pitot\nTeamIdentifier=TESTTEAM01\nAuthority=Developer ID Application: Forged (TESTTEAM01)'
fi

fail() {
  echo "$path: $1" >&2
  exit 3
}

if [[ $verify == 1 ]]; then
  [[ $mode != invalid ]] || fail "invalid signature (code or signature have been modified)"
  [[ -n $requirement ]] || exit 0
  [[ $requirement == =* ]] || fail "the requirement is not given as text"
  [[ $adhoc == 0 ]] || fail "test-requirement: code failed to satisfy specified code requirement(s)"
  for part in 'anchor apple generic' 'certificate 1[field.1.2.840.113635.100.6.2.6] exists' \
    'certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "certificate leaf[subject.OU] = \"$team\""; do
    [[ $requirement == *"$part"* ]] || fail "test-requirement: code failed to satisfy specified code requirement(s)"
  done
  if [[ $requirement == *' identifier "'* ]]; then
    wanted=${requirement##* identifier \"}
    wanted=${wanted%%\"*}
    [[ $wanted == "$identifier" ]] || fail "test-requirement: code failed to satisfy specified code requirement(s)"
  fi
  exit 0
fi

[[ $display == 1 ]] || { echo "stub codesign: nothing to do" >&2; exit 2; }
{
  echo "Executable=$path"
  echo "Identifier=$identifier"
  if [[ $adhoc == 1 ]]; then
    echo "CodeDirectory v=20500 size=550 flags=0x10002(adhoc,runtime) hashes=6+7 location=embedded"
    echo "Signature=adhoc"
    echo "TeamIdentifier=not set"
  else
    echo "CodeDirectory v=20500 size=4541 flags=0x10000(runtime) hashes=131+7 location=embedded"
    echo "Authority=Developer ID Application: Self Test ($team)"
    echo "Authority=Developer ID Certification Authority"
    echo "Authority=Apple Root CA"
    echo "Timestamp=6 Oct 2026 at 22:39:38"
    echo "TeamIdentifier=$team"
  fi
} >&2
