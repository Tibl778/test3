#!/usr/bin/env bash
# One entry point for everything in this repo. Runs locally; GitHub is optional.
#
#   ./ystervos.sh doctor          check that the tools below are installed
#   ./ystervos.sh keys            create your signing keys (once; refuses to overwrite)
#   ./ystervos.sh test            run the add-on tests (headless Chromium) and Mozilla's linter
#   ./ystervos.sh addon           build the add-on, and sign it if keys exist -> dist/
#   ./ystervos.sh apk [version]   build Ystervos from IronFox's release APK    -> out/
#   ./ystervos.sh split           split the APK into <30 MB 7z volumes          -> out/parts/
#   ./ystervos.sh install         adb-install the APK and copy the add-on to the phone's Downloads
#   ./ystervos.sh update          build only if IronFox has a release newer than the last build
#   ./ystervos.sh schedule        run 'update' daily via a systemd user timer (or prints a cron line)
#   ./ystervos.sh all [version]   test + addon + apk + split
#
# Settings (environment variables):
#   YSTERVOS_KEYS   private keys directory   (default: ~/.ystervos/keys)
#   YSTERVOS_OUT    APK output directory     (default: ./out)
#   YSTERVOS_WORK   scratch space, ~2 GB     (default: ./ystervos-build)
#   YSTERVOS_SKIP_LINT=1   skip web-ext lint (it needs npm registry access)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
KEYS="${YSTERVOS_KEYS:-${HOME}/.ystervos/keys}"
OUT="${YSTERVOS_OUT:-${ROOT}/out}"
WORK="${YSTERVOS_WORK:-${ROOT}/ystervos-build}"
ADDON_XPI="${ROOT}/dist/hn-mark-all-read.xpi"
ADDON_SIGNED="${ROOT}/dist/hn-mark-all-read-ystervos-signed.xpi"
ROOT_CERT="${ROOT}/ystervos/certs/ystervos-addons-root.pem"
IRONFOX_API='https://gitlab.com/api/v4/projects/ironfox-oss%2FIronFox'

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" > /dev/null 2>&1; }

need_keys() {
  for f in root-ca.pem signing-ca.pem signing-ca.key; do
    [[ -f "${KEYS}/${f}" ]] || die "missing ${KEYS}/${f}. Run './ystervos.sh keys', or point YSTERVOS_KEYS at your keys folder."
  done
  # The root in the repo must be the root these keys belong to, or Ystervos won't trust what we sign.
  cmp -s <(openssl x509 -in "${KEYS}/root-ca.pem" -outform DER) <(openssl x509 -in "${ROOT_CERT}" -outform DER) ||
    die "${KEYS}/root-ca.pem differs from ${ROOT_CERT}. Copy your root there (and rebuild the APK) or use the matching keys."
}

latest_ironfox() {
  curl -fsSL "${IRONFOX_API}/releases/permalink/latest" |
    python3 -I -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))'
}

cmd_doctor() {
  local ok=1
  for t in bash curl python3 openssl java node npm; do
    if have "$t"; then printf '  ok       %s\n' "$t"; else printf '  MISSING  %s\n' "$t"; ok=0; fi
  done
  if have java; then
    local v; v="$(java -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1)"
    [[ "${v:-0}" -ge 17 ]] && printf '  ok       java %s (17+ needed)\n' "$v" || { printf '  OLD      java %s (17+ needed)\n' "${v:-?}"; ok=0; }
  fi
  if have 7z || python3 -I -c 'import py7zr' 2> /dev/null; then
    printf '  ok       7z or py7zr (for split)\n'
  else
    printf '  optional 7z or py7zr missing (split): install p7zip/7zip, or: python3 -m pip install --user py7zr\n'
  fi
  have adb && printf '  ok       adb (for install)\n' || printf '  optional adb missing (install)\n'
  [[ -d "${KEYS}" ]] && printf '  ok       keys at %s\n' "${KEYS}" || printf '  note     no keys at %s yet (./ystervos.sh keys)\n' "${KEYS}"
  [[ "${ok}" == 1 ]] || die "install the missing tools above"
}

cmd_keys() {
  [[ -e "${KEYS}/root-ca.key" ]] && die "keys already exist in ${KEYS}; refusing to overwrite them"
  say "Creating keys in ${KEYS}"
  "${ROOT}/ystervos/tools/make-keys.sh" "${KEYS}"
  cp "${KEYS}/root-ca.pem" "${ROOT_CERT}"
  say "Copied the public root to ${ROOT_CERT}. Commit it, then rebuild the APK and re-sign the add-on:"
  echo "    ./ystervos.sh addon && ./ystervos.sh apk"
  echo "Back up ${KEYS} somewhere safe. Losing it means a new root and a reinstall of Ystervos."
}

cmd_test() {
  say 'Installing test dependencies'
  (cd "${ROOT}/test" && npm install --no-audit --no-fund --silent)
  say 'Running add-on tests'
  node "${ROOT}/test/test.js"
  if [[ "${YSTERVOS_SKIP_LINT:-0}" != 1 ]]; then
    say 'Linting with web-ext'
    (cd "${ROOT}/test" && npx --yes web-ext@8 lint --source-dir "${ROOT}/extension")
  fi
}

cmd_addon() {
  say 'Building the add-on'
  mkdir -p "${ROOT}/dist"
  python3 -I - "${ROOT}/extension" "${ADDON_XPI}" << 'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
files = ["manifest.json", "content.js", "styles.css"] + [
    os.path.join("icons", f) for f in sorted(os.listdir(os.path.join(src, "icons")))]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in files:
        info = zipfile.ZipInfo(f, date_time=(1980, 1, 1, 0, 0, 0))  # reproducible
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, open(os.path.join(src, f), "rb").read())
print("Built", out)
PY
  if [[ ! -f "${KEYS}/signing-ca.key" ]]; then
    echo "No keys at ${KEYS}: built the unsigned add-on only (fine for testing; Ystervos needs the signed one)."
    return 0
  fi
  need_keys
  say 'Signing it with your key'
  python3 -I "${ROOT}/ystervos/tools/sign-xpi.py" --keys "${KEYS}" "${ADDON_XPI}" "${ADDON_SIGNED}"
  python3 -I "${ROOT}/ystervos/tools/verify-xpi.py" --root "${ROOT_CERT}" "${ADDON_SIGNED}"
}

cmd_apk() {
  need_keys
  [[ -f "${KEYS}/ystervos-apk.jks" && -f "${KEYS}/ystervos-apk.password" ]] || die "missing the APK keystore in ${KEYS}"
  local version="${1:-latest}"
  [[ "${version}" == latest ]] && version="$(latest_ironfox)"
  say "Building Ystervos from IronFox ${version}"
  "${ROOT}/ystervos/patch-apk.sh" "${KEYS}" "${version}" "${WORK}"
  mkdir -p "${OUT}"
  local apk="ystervos-${version}-arm64-v8a.apk"
  mv "${WORK}/${apk}" "${OUT}/${apk}"
  (cd "${OUT}" && sha256sum "${apk}" > "${apk}.sha256")
  echo "${version}" > "${OUT}/.last-ironfox-version"
  say "Done: ${OUT}/${apk}"
}

newest_apk() {
  ls -1 "${OUT}"/ystervos-*-arm64-v8a.apk 2> /dev/null | sort -V | tail -n 1
}

cmd_split() {
  local apk; apk="$(newest_apk)"
  [[ -n "${apk}" ]] || die "no APK in ${OUT}; run './ystervos.sh apk' first"
  say "Splitting $(basename "${apk}") into 7z volumes under 30 MB"
  python3 -I "${ROOT}/ystervos/tools/split-7z.py" "${apk}" "${OUT}/parts"
}

cmd_install() {
  have adb || die "adb is not installed"
  [[ "$(adb get-state 2> /dev/null || true)" == device ]] || die "no phone connected over adb (enable USB debugging and authorize this computer)"
  local apk; apk="$(newest_apk)"
  [[ -n "${apk}" ]] || die "no APK in ${OUT}; run './ystervos.sh apk' first"
  say "Installing $(basename "${apk}")"
  adb install -r "${apk}"
  [[ -f "${ADDON_SIGNED}" ]] && { say 'Copying the add-on to the phone (Download folder)'; adb push "${ADDON_SIGNED}" /sdcard/Download/; }
  cat << 'EOF'
Now on the phone (adb can't press these for you):
  1. Settings > Ystervos settings > Security: turn on "Allow installation of add-ons" (restarts the app).
  2. Settings > About Ystervos: tap the logo 5 times ("Debug menu enabled").
  3. Settings > Advanced > Install extension from file: pick Download/hn-mark-all-read-ystervos-signed.xpi
EOF
}

cmd_update() {
  local latest last
  latest="$(latest_ironfox)"
  last="$(cat "${OUT}/.last-ironfox-version" 2> /dev/null || true)"
  if [[ "${latest}" == "${last}" ]]; then
    echo "IronFox ${latest} already built; nothing to do."
    return 0
  fi
  say "New IronFox release: ${latest} (last built: ${last:-none})"
  cmd_apk "${latest}"
  cmd_split
}

cmd_schedule() {
  if have systemctl && systemctl --user show-environment > /dev/null 2>&1; then
    local dir="${HOME}/.config/systemd/user"
    mkdir -p "${dir}"
    sed "s|REPO|${ROOT}|; s|%h/.ystervos/keys|${KEYS}|" "${ROOT}/ystervos/contrib/ystervos-update.service" > "${dir}/ystervos-update.service"
    cp "${ROOT}/ystervos/contrib/ystervos-update.timer" "${dir}/"
    systemctl --user daemon-reload
    systemctl --user enable --now ystervos-update.timer
    say 'Scheduled daily. Logs: journalctl --user -u ystervos-update.service'
  else
    echo "No systemd user session here. Add this line with 'crontab -e' instead:"
    echo "  17 6 * * * YSTERVOS_KEYS=${KEYS} ${ROOT}/ystervos.sh update >> ${OUT}/update.log 2>&1"
  fi
}

cmd_all() {
  cmd_test
  cmd_addon
  cmd_apk "${1:-latest}"
  cmd_split
}

case "${1:-help}" in
  doctor | keys | test | addon | split | install | update | schedule) "cmd_$1" ;;
  apk | all) cmd="$1"; shift; "cmd_${cmd}" "$@" ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; [[ "${1:-help}" == help ]] || exit 1 ;;
esac
