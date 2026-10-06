#!/bin/bash
# Stands in for `xcrun stapler` in appcast-selftest.sh. STUB_STAPLER_MODE picks the answer:
#   good         every ticket is valid
#   dmgmissing   the DMG has no ticket
#   appmissing   the app has no ticket
set -euo pipefail

mode=${STUB_STAPLER_MODE:-good}
[[ $# == 2 && $1 == validate ]] || { echo "stub stapler: unexpected arguments $*" >&2; exit 2; }
path=$2

case "$mode" in
  good) ;;
  dmgmissing | appmissing)
    if [[ ($mode == dmgmissing && $path == *.dmg) || ($mode == appmissing && $path == *.app) ]]; then
      echo "$path does not have a ticket stapled to it." >&2
      exit 65
    fi
    ;;
  *) echo "stub stapler: unknown STUB_STAPLER_MODE $mode" >&2; exit 2 ;;
esac
echo "The validate action worked!"
