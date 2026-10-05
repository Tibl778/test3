#!/bin/bash
# Called at the end of IronFox's prebuild (installed there by ystervos/apply.sh).
# Replaces "IronFox" with "Ystervos" in user-visible text only:
#   - text content of Android string resources (not resource names, styles or attributes)
#   - Fluent (.ftl) and .properties messages (not comments or identifiers)
# Code, package names and pref names (browser.ironfox.*) are left alone.
#
# Usage: ystervos-rebrand-sources.sh <dir> [<dir> ...]

set -euo pipefail

for root in "$@"; do
  [[ -d "${root}" ]] || continue

  # Android string resources: only text between '>' and '<'.
  find "${root}" -type f -path '*/res/values*' -name '*strings*.xml' -print0 |
    xargs -0 -r grep -lZ 'IronFox' |
    xargs -0 -r perl -pi -e '1 while s/(>[^<]*)IronFox/$1Ystervos/'

  # Fluent and properties files: skip comment lines; identifiers are lowercase, so "IronFox" is always text.
  find "${root}" -type f \( -name '*.ftl' -o -name '*.properties' \) -print0 |
    xargs -0 -r grep -lZ 'IronFox' |
    xargs -0 -r perl -pi -e 'next if /^\s*#/; s/IronFox/Ystervos/g'
done

echo 'Ystervos: rebranded user-visible strings'
