#!/bin/bash
# Stands in for spctl in appcast-selftest.sh. STUB_SPCTL_MODE picks the answer:
#   good      every assessment is accepted
#   rejected  the DMG is rejected
set -euo pipefail

mode=${STUB_SPCTL_MODE:-good}
[[ $1 == --assess ]] || { echo "stub spctl: unexpected arguments $*" >&2; exit 2; }
path=${!#}

case "$mode" in
  good) ;;
  rejected)
    if [[ $path == *.dmg ]]; then
      printf '%s: rejected\nsource=Unnotarized Developer ID\n' "$path" >&2
      exit 3
    fi
    ;;
  *) echo "stub spctl: unknown STUB_SPCTL_MODE $mode" >&2; exit 2 ;;
esac
printf '%s: accepted\nsource=Notarized Developer ID\n' "$path" >&2
