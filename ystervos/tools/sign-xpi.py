#!/usr/bin/env python3
"""Sign a Firefox add-on (.xpi) with the Ystervos add-on signing CA.

Produces the same PKCS#7 layout addons.mozilla.org uses:
  META-INF/manifest.mf   SHA-1 + SHA-256 digests of every file
  META-INF/mozilla.sf    digests of manifest.mf
  META-INF/mozilla.rsa   detached CMS signature (SHA-256) over mozilla.sf,
                         carrying a fresh per-add-on certificate (CN = add-on ID)
                         and the signing CA certificate.

Ystervos trusts the Ystervos root CA alongside Mozilla's AMO root, so the result
installs there like any AMO-signed add-on. Stock Firefox/IronFox will reject it.

Usage:
  sign-xpi.py --keys <dir from make-keys.sh> input.xpi output.xpi
Needs the openssl command line tool.
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

SIGNATURE_FILES = {
    "meta-inf/manifest.mf",
    "meta-inf/mozilla.sf",
    "meta-inf/mozilla.rsa",
    "meta-inf/cose.manifest",
    "meta-inf/cose.sig",
}

EE_EXTENSIONS = """\
[ ee_ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
"""


def b64(data):
    return base64.b64encode(data).decode("ascii")


def manifest_line(text):
    """JAR manifest lines are at most 72 bytes; longer ones continue with a leading space."""
    raw = text.encode("utf-8")
    out = [raw[:72]]
    raw = raw[72:]
    while raw:
        out.append(b" " + raw[:71])
        raw = raw[71:]
    return b"\n".join(out) + b"\n"


def addon_id(zf):
    manifest = json.loads(zf.read("manifest.json").decode("utf-8-sig"))
    for key in ("browser_specific_settings", "applications"):
        gecko = manifest.get(key, {}).get("gecko", {})
        if gecko.get("id"):
            return gecko["id"]
    sys.exit("manifest.json has no browser_specific_settings.gecko.id; an ID is required for signing")


def openssl(*args):
    subprocess.run(["openssl", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keys", required=True, help="directory holding signing-ca.pem and signing-ca.key")
    ap.add_argument("input")
    ap.add_argument("output")
    args = ap.parse_args()

    ca_cert = os.path.join(args.keys, "signing-ca.pem")
    ca_key = os.path.join(args.keys, "signing-ca.key")

    with zipfile.ZipFile(args.input) as zin:
        entries = [
            (info, zin.read(info))
            for info in zin.infolist()
            if not info.is_dir() and info.filename.lower() not in SIGNATURE_FILES
        ]
        ext_id = addon_id(zin)

    # Firefox compares the certificate CN to the ID, hashing IDs longer than 64 chars.
    cn = ext_id if len(ext_id) <= 64 else hashlib.sha256(ext_id.encode()).hexdigest()

    mf = b"Manifest-Version: 1.0\n\n"
    for info, data in entries:
        mf += manifest_line("Name: " + info.filename)
        mf += b"Digest-Algorithms: SHA1 SHA256\n"
        mf += b"SHA1-Digest: " + b64(hashlib.sha1(data).digest()).encode() + b"\n"
        mf += b"SHA256-Digest: " + b64(hashlib.sha256(data).digest()).encode() + b"\n\n"

    sf = (
        b"Signature-Version: 1.0\n"
        + b"SHA1-Digest-Manifest: " + b64(hashlib.sha1(mf).digest()).encode() + b"\n"
        + b"SHA256-Digest-Manifest: " + b64(hashlib.sha256(mf).digest()).encode() + b"\n\n"
    )

    with tempfile.TemporaryDirectory() as tmp:
        p = lambda name: os.path.join(tmp, name)
        with open(p("ext.cnf"), "w") as f:
            f.write(EE_EXTENSIONS)
        with open(p("mozilla.sf"), "wb") as f:
            f.write(sf)

        # A fresh key and certificate for this add-on, like AMO issues.
        subj_cn = cn.replace("\\", "\\\\").replace("/", "\\/")
        openssl("req", "-new", "-newkey", "rsa:4096", "-nodes", "-keyout", p("ee.key"), "-out", p("ee.csr"),
                "-subj", f"/O=Ystervos/OU=Ystervos Extensions/CN={subj_cn}")
        openssl("x509", "-req", "-in", p("ee.csr"), "-CA", ca_cert, "-CAkey", ca_key,
                "-set_serial", str(int.from_bytes(os.urandom(16), "big") >> 1),
                "-sha384", "-days", "3653", "-extfile", p("ext.cnf"), "-extensions", "ee_ext",
                "-out", p("ee.pem"))
        openssl("cms", "-sign", "-binary", "-in", p("mozilla.sf"), "-signer", p("ee.pem"), "-inkey", p("ee.key"),
                "-certfile", ca_cert, "-md", "sha256", "-nosmimecap", "-outform", "DER", "-out", p("mozilla.rsa"))
        with open(p("mozilla.rsa"), "rb") as f:
            rsa = f.read()

    with zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED) as zout:
        for name, data in (("META-INF/mozilla.rsa", rsa), ("META-INF/mozilla.sf", sf), ("META-INF/manifest.mf", mf)):
            zout.writestr(zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0)), data, zipfile.ZIP_DEFLATED)
        for info, data in entries:
            zout.writestr(info, data, zipfile.ZIP_DEFLATED)

    print(f"Signed {ext_id} -> {args.output}")


if __name__ == "__main__":
    main()
