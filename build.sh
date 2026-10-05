#!/bin/sh
# Packages extension/ into dist/hn-mark-all-read.xpi (a zip with manifest.json at the root).
set -e
cd "$(dirname "$0")"
mkdir -p dist
rm -f dist/hn-mark-all-read.xpi
(cd extension && zip -r -X -q ../dist/hn-mark-all-read.xpi manifest.json content.js styles.css icons)
echo "Built dist/hn-mark-all-read.xpi"
