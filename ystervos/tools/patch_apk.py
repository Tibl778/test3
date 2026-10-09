#!/usr/bin/env python3
"""Ystervos APK patch steps, applied to an apktool-decoded IronFox release.

Called by ystervos/patch-apk.sh; see that script for the whole flow. Steps:

  libxul   Replace Mozilla's add-on *stage* root certificate (used only for testing) inside
           libxul.so with the Ystervos root. The two are the same length, so nothing else moves.
  omni     In assets/omni.ja: verify add-ons against Mozilla's AMO root first and fall back to
           the stage slot (now the Ystervos root) only when the chain is unknown. Rename the
           brand strings.
  app      Rename the package ID and the user-visible app name in the manifest, resources and code.
"""

import argparse
import io
import os
import re
import sys
import zipfile

OLD_ID = "org.ironfoxoss.ironfox"
OLD_NAME = "IronFox"


def die(msg):
    sys.exit("ERROR: " + msg)


def pem_to_der(path):
    import base64
    text = open(path).read()
    m = re.search(r"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", text, re.S)
    if not m:
        die(f"{path} holds no PEM certificate")
    return base64.b64decode("".join(m.group(1).split()))


def patch_libxul(libxul, stage_root, ystervos_root):
    old, new = pem_to_der(stage_root), pem_to_der(ystervos_root)
    if len(old) != len(new):
        die(f"the Ystervos root is {len(new)} bytes but the stage root slot is {len(old)} bytes; "
            "re-issue the root with tools/fit-root.py <keys-dir> " + str(len(old)))
    data = open(libxul, "rb").read()
    count = data.count(old)
    if count == 0:
        if data.count(new):
            print("libxul: already patched")
            return
        die("Mozilla's add-on stage root was not found in libxul.so")
    open(libxul, "wb").write(data.replace(old, new))
    print(f"libxul: replaced {count} copies of the add-on stage root with the Ystervos root")


# IronFox 157's minified verifySignedState. If a later release changes it, this fails loudly.
VERIFY_RE = re.compile(
    r"async verifySignedState\((\w),(\w),(\w)\)\{if\(!shouldVerifySignedState\(\2,\3\)\)"
    r"return\{signedState:AddonManager\.SIGNEDSTATE_NOT_REQUIRED,cert:null\};"
    r"let (\w)=Ci\.nsIX509CertDB\.AddonsPublicRoot;return\(.*?\)&&Services\.prefs\.getBoolPref\("
    r"PREF_XPI_SIGNATURES_DEV_ROOT,!1\)&&\(\4=Ci\.nsIX509CertDB\.AddonsStageRoot\),"
    r"this\.verifySignedStateForRoot\(\1,\4\)\}"
)


def verify_replacement(m):
    e, t, a, n = m.groups()
    return (
        f"async verifySignedState({e},{t},{a}){{if(!shouldVerifySignedState({t},{a}))"
        f"return{{signedState:AddonManager.SIGNEDSTATE_NOT_REQUIRED,cert:null}};"
        # Ystervos: AMO first; the stage slot holds the Ystervos root and is tried only when the
        # signature does not chain to AMO. Unsigned (MISSING) and tampered (BROKEN) stay rejected.
        f"let {n}=await this.verifySignedStateForRoot({e},Ci.nsIX509CertDB.AddonsPublicRoot);"
        f"return {n}.signedState===AddonManager.SIGNEDSTATE_UNKNOWN&&"
        f"({n}=await this.verifySignedStateForRoot({e},Ci.nsIX509CertDB.AddonsStageRoot)),{n}}}"
    )


def rename_text(text, name):
    out = []
    for line in text.splitlines(keepends=True):
        out.append(line if line.lstrip().startswith("#") else line.replace(OLD_NAME, name))
    return "".join(out)


def patch_omni(omni, name):
    src = zipfile.ZipFile(omni)
    buf = io.BytesIO()
    dst = zipfile.ZipFile(buf, "w")
    verify_done = renamed = 0
    for info in src.infolist():
        data = src.read(info)
        if info.filename == "modules/addons/XPIInstall.sys.mjs":
            text, n = VERIFY_RE.subn(verify_replacement, data.decode())
            if n != 1:
                if "verifySignedStateForRoot(e,Ci.nsIX509CertDB.AddonsStageRoot)" in text:
                    n = 1  # already patched
                else:
                    die("could not find verifySignedState in XPIInstall.sys.mjs (IronFox changed it)")
            data, verify_done = text.encode(), n
        elif info.filename.endswith((".ftl", ".properties")) and OLD_NAME.encode() in data:
            data = rename_text(data.decode("utf-8"), name).encode("utf-8")
            renamed += 1
        dst.writestr(info, data, compress_type=info.compress_type)
    dst.close()
    if not verify_done:
        die("XPIInstall.sys.mjs not found in omni.ja")
    open(omni, "wb").write(buf.getvalue())
    print(f"omni.ja: add-on root fallback added; renamed brand text in {renamed} files")


def patch_app(dec, new_id, name):
    # Manifest: package, providers, permissions, launcher aliases, shared user ID.
    manifest = os.path.join(dec, "AndroidManifest.xml")
    text = open(manifest).read()
    n = text.count(OLD_ID)
    if n == 0:
        die("package ID not found in AndroidManifest.xml")
    open(manifest, "w").write(text.replace(OLD_ID, new_id))
    print(f"manifest: {n} references to {OLD_ID} -> {new_id}")

    # Launcher shortcuts target the package.
    for root, _, files in os.walk(os.path.join(dec, "res")):
        for f in files:
            p = os.path.join(root, f)
            if root.split(os.sep)[-1].startswith("xml") and f.endswith(".xml"):
                t = open(p, encoding="utf-8").read()
                if f'"{OLD_ID}"' in t:
                    open(p, "w", encoding="utf-8").write(t.replace(f'"{OLD_ID}"', f'"{new_id}"'))
                    print(f"resources: package ID in {os.path.relpath(p, dec)}")

    # Code: only the bare package-ID string constant (BuildConfig.APPLICATION_ID, inlined).
    # Class names such as org.ironfoxoss.ironfox.utils.* are left alone.
    hits = 0
    for d in sorted(os.listdir(dec)):
        if not d.startswith("smali"):
            continue
        for root, _, files in os.walk(os.path.join(dec, d)):
            for f in files:
                p = os.path.join(root, f)
                t = open(p, encoding="utf-8").read()
                if f'"{OLD_ID}"' in t:
                    open(p, "w", encoding="utf-8").write(t.replace(f'"{OLD_ID}"', f'"{new_id}"'))
                    hits += t.count(f'"{OLD_ID}"')
    print(f"code: {hits} package-ID constants -> {new_id}")

    # User-visible strings in every language (text nodes only, not resource names).
    changed = 0
    pat = re.compile(r"(>[^<]*?)" + OLD_NAME)
    for root, _, files in os.walk(os.path.join(dec, "res")):
        if not os.path.basename(root).startswith("values"):
            continue
        for f in files:
            if "strings" not in f or not f.endswith(".xml"):
                continue
            p = os.path.join(root, f)
            t = open(p, encoding="utf-8").read()
            if OLD_NAME not in t:
                continue
            new = t
            while True:
                nxt = pat.sub(lambda m: m.group(1) + name, new)
                if nxt == new:
                    break
                new = nxt
            if new != t:
                open(p, "w", encoding="utf-8").write(new)
                changed += 1
    print(f"strings: renamed {OLD_NAME} -> {name} in {changed} files")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--decoded", required=True, help="apktool-decoded IronFox APK")
    ap.add_argument("--stage-root", required=True, help="Mozilla's addons-stage.pem")
    ap.add_argument("--root", required=True, help="Ystervos root CA (same DER length as the stage root)")
    ap.add_argument("--app-id", default="org.ystervos.browser")
    ap.add_argument("--name", default="Ystervos")
    a = ap.parse_args()

    libs = [os.path.join(r, f) for r, _, fs in os.walk(os.path.join(a.decoded, "lib")) for f in fs if f == "libxul.so"]
    if not libs:
        die("no libxul.so in the decoded APK")
    for lib in libs:
        patch_libxul(lib, a.stage_root, a.root)
    patch_omni(os.path.join(a.decoded, "assets", "omni.ja"), a.name)
    patch_app(a.decoded, a.app_id, a.name)


if __name__ == "__main__":
    main()
