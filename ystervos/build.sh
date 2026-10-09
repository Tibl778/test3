#!/bin/bash
# Builds a signed Ystervos APK (arm64) from an IronFox release, inside IronFox's Docker build image.
#
# Usage: ystervos/build.sh <keys-dir> [ironfox-tag] [work-dir]
#   keys-dir     output of tools/make-keys.sh (needs ystervos-apk.jks and ystervos-apk.password)
#   ironfox-tag  IronFox release tag to build (default: v157.0.0.1, the release these patches were made for)
#   work-dir     where to clone and build (default: ./ystervos-build)
#
# Needs: git, Docker, a fast connection, roughly 80 GB of free disk and 16 GB of RAM.
# A first build takes several hours.

set -euo pipefail

readonly here="$(cd "$(dirname "$0")" && pwd)"
readonly keys="$(cd "${1:?usage: build.sh <keys-dir> [ironfox-tag] [work-dir]}" && pwd)"
readonly tag="${2:-v157.0.0.1}"
readonly work="${3:-${PWD}/ystervos-build}"

for f in ystervos-apk.jks ystervos-apk.password; do
  [[ -f "${keys}/${f}" ]] || { echo "ERROR: ${keys}/${f} is missing" >&2; exit 1; }
done

if [[ ! -d "${work}/.git" ]]; then
  git clone --depth 1 --branch "${tag}" https://gitlab.com/ironfox-oss/IronFox.git "${work}"
fi
"${here}/apply.sh" "${work}"

cd "${work}"
./scripts/run-docker.sh -v "${keys}:/keys:ro" -- bash -c '
  set -euo pipefail
  export IRONFOX_RELEASE=1
  export IRONFOX_SIGN=1
  export IRONFOX_SIGN_SKIP_ADB=1
  export IRONFOX_ANDROID_KEYSTORE=/keys/ystervos-apk.jks
  export IRONFOX_ANDROID_KEYSTORE_PASS_FILE=/keys/ystervos-apk.password
  export IRONFOX_ANDROID_KEYSTORE_KEY_PASS_FILE=/keys/ystervos-apk.password
  export IRONFOX_ANDROID_KEYSTORE_KEY_ALIAS=ystervos
  ./scripts/get_sources.sh
  ./scripts/prebuild.sh
  ./scripts/build.sh arm64
'

echo
echo "Built APKs:"
find "${work}/outputs" -name '*.apk' -newer "${work}/.ystervos-applied" -print
