#!/usr/bin/env python3
"""Check an .xpi's PKCS#7 signature the way Gecko's AppSignatureVerification does.

  verify-xpi.py --root <root-ca.pem> file.xpi

Checks: every file is listed in manifest.mf with a matching SHA-256 digest, and nothing
is unlisted; mozilla.sf matches manifest.mf; the CMS signature over mozilla.sf verifies
(SHA-256) and chains to --root through the certificates embedded in it; the signer has
the code-signing EKU and its CN equals the add-on ID. Exit status 0 means it passes.
"""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import zipfile

SIG_FILES = {"meta-inf/manifest.mf", "meta-inf/mozilla.sf", "meta-inf/mozilla.rsa",
             "meta-inf/cose.manifest", "meta-inf/cose.sig"}


def parse_sections(text):
    sections, cur, last = [], {}, None
    for line in text.split("\n"):
        if line.startswith(" ") and last:
            cur[last] += line[1:]
        elif line == "":
            if cur:
                sections.append(cur)
            cur, last = {}, None
        else:
            k, _, v = line.partition(": ")
            cur[k.lower()] = v
            last = k.lower()
    if cur:
        sections.append(cur)
    return sections


def fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("xpi")
    a = ap.parse_args()

    z = zipfile.ZipFile(a.xpi)
    names = {i.filename for i in z.infolist() if not i.is_dir()}
    for need in ("META-INF/manifest.mf", "META-INF/mozilla.sf", "META-INF/mozilla.rsa"):
        if need not in names:
            fail(f"missing {need}")
    mf, sf, rsa = (z.read("META-INF/" + n) for n in ("manifest.mf", "mozilla.sf", "mozilla.rsa"))

    sfh = parse_sections(sf.decode())[0]
    if sfh.get("sha256-digest-manifest") != base64.b64encode(hashlib.sha256(mf).digest()).decode():
        fail("mozilla.sf SHA256-Digest-Manifest does not match manifest.mf")

    listed = {}
    for s in parse_sections(mf.decode())[1:]:
        listed[s["name"]] = s.get("sha256-digest")
    for n in names:
        if n.lower() in SIG_FILES:
            continue
        if n not in listed:
            fail(f"unsigned entry {n}")
        if listed[n] != base64.b64encode(hashlib.sha256(z.read(n)).digest()).decode():
            fail(f"digest mismatch for {n}")
    for n in listed:
        if n not in names and n.lower() not in SIG_FILES:
            fail(f"manifest lists missing entry {n}")

    with tempfile.TemporaryDirectory() as t:
        open(os.path.join(t, "sf"), "wb").write(sf)
        open(os.path.join(t, "rsa"), "wb").write(rsa)
        r = subprocess.run(["openssl", "cms", "-verify", "-binary", "-inform", "DER", "-in", os.path.join(t, "rsa"),
                            "-content", os.path.join(t, "sf"), "-CAfile", a.root, "-purpose", "any",
                            "-signer", os.path.join(t, "signer.pem"), "-out", os.devnull],
                           capture_output=True, text=True)
        if r.returncode != 0:
            fail("CMS signature does not verify against the root: " + r.stderr.strip())
        printed = subprocess.run(["openssl", "cms", "-cmsout", "-print", "-inform", "DER", "-in",
                                  os.path.join(t, "rsa")], capture_output=True, text=True).stdout
        if "digestAlgorithm: \n          algorithm: sha256" not in printed and "sha256 (2.16.840.1.101.3.4.2.1)" not in printed:
            fail("signer digest is not SHA-256 (Firefox treats SHA-1 as weak)")
        text = subprocess.run(["openssl", "x509", "-in", os.path.join(t, "signer.pem"), "-noout", "-text",
                               "-nameopt", "multiline"], capture_output=True, text=True).stdout
        if "Code Signing" not in text:
            fail("signer certificate lacks the code-signing EKU")
        cn = subprocess.run(["openssl", "x509", "-in", os.path.join(t, "signer.pem"), "-noout", "-subject",
                             "-nameopt", "sep_multiline,utf8"], capture_output=True, text=True).stdout
        cn = [l.split("=", 1)[1] for l in cn.splitlines() if l.strip().startswith("CN=")][0]

    m = json.loads(z.read("manifest.json").decode("utf-8-sig"))
    ext_id = (m.get("browser_specific_settings") or m.get("applications") or {}).get("gecko", {}).get("id")
    expected = ext_id if len(ext_id) <= 64 else hashlib.sha256(ext_id.encode()).hexdigest()
    if cn != expected:
        fail(f"signer CN {cn!r} does not match add-on ID {ext_id!r}")
    print(f"OK: {ext_id} ({len(listed)} files) signed by a certificate chaining to {os.path.basename(a.root)}")


if __name__ == "__main__":
    main()
