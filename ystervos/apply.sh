#!/bin/bash
# Turns an IronFox source checkout into Ystervos:
#   - renames the app to "Ystervos" (launcher, about pages, settings text)
#   - gives it its own package ID (org.ystervos.browser) so it installs next to IronFox
#   - makes Gecko trust add-ons signed with the Ystervos add-on root CA, as well as AMO-signed ones
#
# Usage: ystervos/apply.sh <path to IronFox checkout>
# Run it once on a clean checkout, before IronFox's get_sources/prebuild/build scripts.

set -euo pipefail

readonly here="$(cd "$(dirname "$0")" && pwd)"
readonly ironfox="$(cd "${1:?usage: apply.sh <IronFox checkout>}" && pwd)"
readonly name='Ystervos'
readonly app_id_prefix='org.ystervos'
readonly app_id_release='browser'
readonly app_id_nightly='browser.nightly'

cd "${ironfox}"

if [[ -f .ystervos-applied ]]; then
  echo "Ystervos changes are already applied to ${ironfox}"
  exit 0
fi

# Replace an exact string in a file, failing loudly if IronFox changed and it isn't there.
replace() {
  local -r file="$1" from="$2" to="$3"
  if ! grep -qF -- "${from}" "${file}"; then
    echo "ERROR: expected text not found in ${file}: ${from}" >&2
    exit 1
  fi
  FROM="${from}" TO="${to}" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "${file}"
}

echo '--> Gecko: trust the Ystervos add-on root'
cp "${here}/patches/gecko-ystervos-trust-addon-root.patch" patches/
cat >> scripts/patches.yaml << 'EOF'

  - file: "gecko-ystervos-trust-addon-root.patch"
    name: "Gecko - Ystervos add-on signing root"
    description: "Adds the Ystervos root CA to the trusted add-on signing roots, next to Mozilla's AMO root."
    reason: "To install add-ons signed with the Ystervos signing key while keeping signature enforcement on."
    effect: "Add-ons signed by AMO or by the Ystervos key install; unsigned add-ons are still rejected."
    category: "Security"
EOF

echo '--> Name'
replace scripts/env_common.sh "readonly IRONFOX_NAME='IronFox'" "readonly IRONFOX_NAME='${name}'"
replace scripts/env_common.sh "readonly IRONFOX_NAME='IronFox Nightly'" "readonly IRONFOX_NAME='${name} Nightly'"
replace scripts/build-if.sh "[[ \"\${IRONFOX_NAME}\" != 'IronFox' ]] && [[ \"\${IRONFOX_NAME}\" != 'IronFox Nightly' ]]" \
  "[[ \"\${IRONFOX_NAME}\" != '${name}' ]] && [[ \"\${IRONFOX_NAME}\" != '${name} Nightly' ]]"

for dir in patches/gecko-overlay/ironfox/branding/ironfox patches/gecko-overlay/ironfox/branding/ironfox-nightly; do
  replace "${dir}/configure.sh" "MOZ_APP_DISPLAYNAME='IronFox" "MOZ_APP_DISPLAYNAME='${name}"
  replace "${dir}/locales/en-US/brand.ftl" "-brand-short-name = IronFox" "-brand-short-name = ${name}"
  replace "${dir}/locales/en-US/brand.properties" "brandShortName=IronFox" "brandShortName=${name}"
  # Any remaining display names in the branding files (full name, product name, ...).
  find "${dir}" -type f \( -name '*.ftl' -o -name '*.properties' \) -exec perl -pi -e 'next if /^\s*#/; s/IronFox/'"${name}"'/g' {} +
done

echo '--> Package ID'
replace scripts/build-if.sh "local -r fenix_app_id_suffix='ironfox'" "local -r fenix_app_id_suffix='${app_id_release}'"
replace scripts/build-if.sh "local -r fenix_app_id_suffix='ironfox.nightly'" "local -r fenix_app_id_suffix='${app_id_nightly}'"
replace scripts/build-if.sh 'local -r fenix_app_id="org.ironfoxoss.${fenix_app_id_suffix}"' \
  "local -r fenix_app_id=\"${app_id_prefix}.\${fenix_app_id_suffix}\""
replace scripts/build-if.sh "s|applicationId \"org.mozilla\"|applicationId \"org.ironfoxoss\"|g" \
  "s|applicationId \"org.mozilla\"|applicationId \"${app_id_prefix}\"|g"
replace scripts/build-if.sh '"sharedUserId": "org.ironfoxoss.ironfox.sharedID"' "\"sharedUserId\": \"${app_id_prefix}.${app_id_release}.sharedID\""
replace patches/gecko-overlay/ironfox/ironfox.configure 'return "org.ironfoxoss.ironfox"' "return \"${app_id_prefix}.${app_id_release}\""
replace patches/gecko-overlay/ironfox/ironfox.configure 'return "org.ironfoxoss.ironfox.nightly"' "return \"${app_id_prefix}.${app_id_nightly}\""

echo '--> User-visible text (runs after prebuild has patched the sources)'
install -m 755 "${here}/rebrand-sources.sh" scripts/ystervos-rebrand-sources.sh
replace scripts/prebuild-if.sh 'echo_green_text "SUCCESS: Prepared to build IronFox ${IRONFOX_VERSION}!"' \
  '/bin/bash "${IRONFOX_SCRIPTS}/ystervos-rebrand-sources.sh" "${IRONFOX_GECKO}" "${IRONFOX_TEMP}"
echo_green_text "SUCCESS: Prepared to build Ystervos (IronFox ${IRONFOX_VERSION})!"'

touch .ystervos-applied
echo "Done. ${ironfox} now builds Ystervos (${app_id_prefix}.${app_id_release})."
