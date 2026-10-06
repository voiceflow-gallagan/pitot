#!/bin/bash
# Stands in for Sparkle's generate_appcast in appcast-selftest.sh. STUB_MODE picks the output. The XML
# copies the layout that generate_appcast 2.10.0 writes, including the feed signature after </rss>.
set -euo pipefail

if [[ -n ${STUB_MARKER:-} ]]; then
  touch "$STUB_MARKER"
fi
if [[ -n ${STUB_ARGS:-} ]]; then
  printf '%s\n' "$@" >"$STUB_ARGS"
fi

account=ed25519
prefix=""
out=""
deltas=""
embed=0
while [[ $# -gt 1 ]]; do
  case "$1" in
    --account) account=$2; shift 2 ;;
    --download-url-prefix) prefix=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    --maximum-deltas) deltas=$2; shift 2 ;;
    --embed-release-notes) embed=1; shift ;;
    # Anything else, such as a key on the command line, is a bug in appcast.sh.
    *) echo "stub: unexpected argument $1" >&2; exit 2 ;;
  esac
done
dir=$1
[[ $deltas == 0 ]] || { echo "stub: --maximum-deltas 0 is missing" >&2; exit 2; }
[[ -n $prefix && -n $out ]] || { echo "stub: --download-url-prefix and -o are required" >&2; exit 2; }
dmg=$(cd "$dir" && ls -- *.dmg)

url="$prefix$dmg"
version=$STUB_VERSION
signature=' sparkle:edSignature="vWmwhKDV+FCaH/+dm8BmBhi3FixHsZ69CXq7dUl3MPgpvzatPu+ZZrJcwUgiq4ZQytFWsbz7p8qFo99ADfYIDQ=="'
deltas_xml=""
description=""
feed_signed=1
length_offset=0
if [[ $embed == 1 ]]; then
  notes=""
  for file in "$dir/${dmg%.dmg}".html "$dir/${dmg%.dmg}".md "$dir/${dmg%.dmg}".txt; do
    if [[ -f $file ]]; then
      notes=$(cat "$file")
    fi
  done
  description="
            <description><![CDATA[$notes]]></description>"
fi

case "${STUB_MODE:-good}" in
  good) ;;
  nokey)
    echo "Warning: Private key for account $account not found in the Keychain (-25300). Please run the generate_keys tool" >&2
    exit 1
    ;;
  mismatch)
    echo "Warning: SUPublicEDKey in the app $dir/$dmg does not match key EdDSA in the Keychain. Run generate_keys and update Info.plist to match" >&2
    ;;
  nosig) signature="" ;;
  nofeedsig) feed_signed=0 ;;
  badlength) length_offset=1 ;;
  delta)
    deltas_xml="
            <sparkle:deltas>
                <enclosure url=\"${prefix}Pitot9.8.7-9.8.6.delta\" sparkle:deltaFrom=\"9.8.6\" length=\"100\" type=\"application/octet-stream\"$signature></enclosure>
            </sparkle:deltas>"
    ;;
  httpurl) url="http://${prefix#https://}$dmg" ;;
  wrongversion) version=0.0.1 ;;
  *) echo "stub: unknown STUB_MODE $STUB_MODE" >&2; exit 2 ;;
esac

cat >"$out" <<EOF
<?xml version="1.0" standalone="yes"?><!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires re-signing this file with generate_appcast or sign_update! The signed signature will be embedded at the end of this file.
--><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Pitot</title>
        <item>
            <title>$version</title>
            <pubDate>Tue, 06 Oct 2026 22:46:51 +0200</pubDate>
            <sparkle:version>$version</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>$description
            <enclosure url="$url" length="20778" type="application/octet-stream"$signature></enclosure>$deltas_xml
        </item>
    </channel>
</rss>
EOF
# Like generate_appcast: the signature comment follows </rss> directly, and its length is the number of
# signed bytes before it.
if [[ $feed_signed == 1 ]]; then
  body=$(cat "$out")
  printf '%s' "$body" >"$out"
  length=$(($(wc -c <"$out") + length_offset))
  printf '<!-- sparkle-signatures:\nedSignature: 4w74KEcNX1CJBcvl10LY/AenfFuEIasKkgWy61oqsVcvJUaC3GIyfxpB4qCNgVaYrLDhSeahMy2aW9KqC3U/DA==\nlength: %s\n-->\n' "$length" >>"$out"
fi
echo "Wrote 1 new update, updated 0 existing updates, and removed 0 old updates in appcast.xml"
