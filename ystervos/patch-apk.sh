#!/bin/bash
# Makes a Ystervos APK from an official IronFox release, without compiling anything.
#
# Usage: ystervos/patch-apk.sh <keys-dir> [ironfox-version] [work-dir]
#   keys-dir         output of tools/make-keys.sh
#   ironfox-version  e.g. 157.0.1; default: IronFox's latest release. Its APK must still be in
#                    IronFox's F-Droid repo on GitLab, which keeps only the newest release.
#   work-dir         scratch space, about 2 GB (default: ./ystervos-build)
#
# Needs: bash, curl, python3, openssl, Java 17+, node (optional, to syntax-check the JS change).
#
# Steps: download the arm64 release APK and check its SHA-512 against IronFox's published sum,
# decode it with apktool, apply tools/patch_apk.py (add-on root, rename, package ID), rebuild,
# then zipalign and sign with your keystore.

set -euo pipefail

readonly here="$(cd "$(dirname "$0")" && pwd)"
readonly keys="$(cd "${1:?usage: patch-apk.sh <keys-dir> [ironfox-version] [work-dir]}" && pwd)"
version="${2:-latest}"
readonly work="${3:-${PWD}/ystervos-build}"
readonly repo='https://gitlab.com/ironfox-oss/fdroid/-/raw/HEAD/fdroid/repo'
readonly api='https://gitlab.com/api/v4/projects/ironfox-oss%2FIronFox'
readonly apktool_url='https://github.com/iBotPeaches/Apktool/releases/download/v2.12.1/apktool_2.12.1.jar'
readonly signer_url='https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/uber-apk-signer-1.3.0.jar'

mkdir -p "${work}/download" "${work}/tools"
cd "${work}"

if [[ "${version}" == latest ]]; then
  version="$(curl -fsSL "${api}/releases/permalink/latest" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')"
  echo "--> Latest IronFox release: ${version}"
fi
readonly version

# Mozilla's add-on stage root, taken from the exact Firefox commit this IronFox release is built on.
gecko_commit="$(curl -fsSL "https://gitlab.com/ironfox-oss/IronFox/-/raw/v${version}/scripts/versions.sh" |
  sed -n "s/^readonly IRONFOX_GECKO_COMMIT='\([0-9a-f]*\)'.*/\1/p")"
[[ -n "${gecko_commit}" ]] || { echo "ERROR: could not find the Firefox commit for IronFox ${version}" >&2; exit 1; }
readonly stage_root_url="https://raw.githubusercontent.com/mozilla-firefox/firefox/${gecko_commit}/security/manager/ssl/addons-stage.pem"

fetch() { [[ -s "$2" ]] || curl -fsSL --retry 3 -o "$2" "$1"; }

echo "--> Downloading IronFox ${version} (arm64)"
apk="download/ironfox-${version}-arm64-v8a.apk"
fetch "${repo}/ironfox-${version}-arm64-v8a.apk" "${apk}"
fetch "${repo}/ironfox-${version}-arm64-v8a.apk-sha512sum.txt" "${apk}.sha512"
expected="$(head -c 128 "${apk}.sha512")"
actual="$(sha512sum "${apk}" | cut -c1-128)"
[[ "${expected}" == "${actual}" ]] || { echo "ERROR: SHA-512 mismatch for ${apk}" >&2; exit 1; }
echo "    SHA-512 matches IronFox's published checksum"

fetch "${apktool_url}" tools/apktool.jar
fetch "${signer_url}" tools/uber-apk-signer.jar
fetch "${stage_root_url}" "tools/addons-stage-${gecko_commit}.pem"

echo '--> Decoding'
rm -rf decoded
java -Xmx8g -jar tools/apktool.jar d -f -o decoded "${apk}" > /dev/null

echo '--> Patching'
python3 -I "${here}/tools/patch_apk.py" --decoded decoded --stage-root "tools/addons-stage-${gecko_commit}.pem" --root "${keys}/root-ca.pem"
if command -v node > /dev/null; then
  tmp="$(mktemp -d)"
  unzip -q -o decoded/assets/omni.ja modules/addons/XPIInstall.sys.mjs -d "${tmp}"
  cp "${tmp}/modules/addons/XPIInstall.sys.mjs" "${tmp}/check.mjs"
  node --check "${tmp}/check.mjs"
  rm -rf "${tmp}"
fi

echo '--> Rebuilding'
java -Xmx8g -jar tools/apktool.jar b -o "ystervos-${version}-unsigned.apk" decoded > /dev/null

echo '--> Signing'
pass="$(cat "${keys}/ystervos-apk.password")"
rm -rf signed
java -jar tools/uber-apk-signer.jar -a "ystervos-${version}-unsigned.apk" -o signed \
  --ks "${keys}/ystervos-apk.jks" --ksAlias ystervos --ksPass "${pass}" --ksKeyPass "${pass}" > /dev/null
mv signed/*-aligned-signed.apk "ystervos-${version}-arm64-v8a.apk"
rm -rf signed "ystervos-${version}-unsigned.apk"

echo "Done: ${work}/ystervos-${version}-arm64-v8a.apk"
