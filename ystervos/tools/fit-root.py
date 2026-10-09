#!/usr/bin/env python3
"""Re-issue the Ystervos root CA (same key, same name) at an exact DER length.

patch-apk.sh writes the root into libxul.so over Mozilla's add-on stage root, so both must be
the same number of bytes. The length is tuned with padding in a non-critical comment extension.
Certificates already issued by the root stay valid: the key and subject are unchanged.

Usage: fit-root.py <keys-dir> [target-length]     (default 1608, the stage root's length)
Writes <keys-dir>/root-ca.pem; the previous one is kept as root-ca.prev.pem.
"""

import os
import subprocess
import sys
import tempfile

keys = sys.argv[1]
target = int(sys.argv[2]) if len(sys.argv) > 2 else 1608
key = os.path.join(keys, "root-ca.key")


def issue(pad, out_pem, tmp):
    cnf = os.path.join(tmp, "root.cnf")
    with open(cnf, "w") as f:
        f.write(
            "[ req ]\ndistinguished_name = dn\nprompt = no\n[ dn ]\n"
            "[ root_ext ]\nbasicConstraints = critical, CA:true\n"
            "keyUsage = critical, keyCertSign, cRLSign\nsubjectKeyIdentifier = hash\n"
            f'nsComment = "Ystervos add-on root {"x" * pad}"\n'
        )
    subprocess.run(["openssl", "req", "-new", "-x509", "-key", key, "-sha384", "-days", "9131",
                    "-subj", "/O=Ystervos/OU=Ystervos Add-on Signing/CN=Ystervos Add-on Root CA",
                    "-set_serial", "0x5973746572766f7301", "-config", cnf, "-extensions", "root_ext",
                    "-out", out_pem], check=True, capture_output=True)
    der = subprocess.run(["openssl", "x509", "-in", out_pem, "-outform", "DER"],
                         check=True, capture_output=True).stdout
    return len(der)


with tempfile.TemporaryDirectory() as tmp:
    pem = os.path.join(tmp, "root.pem")
    pad = 0
    for _ in range(12):
        n = issue(pad, pem, tmp)
        if n == target:
            break
        pad += target - n
    else:
        sys.exit(f"could not reach {target} bytes (last: {n})")
    cur = os.path.join(keys, "root-ca.pem")
    if os.path.exists(cur):
        os.replace(cur, os.path.join(keys, "root-ca.prev.pem"))
    os.replace(pem, cur)

print(f"root-ca.pem re-issued at {target} bytes")
