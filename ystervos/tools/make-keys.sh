#!/bin/sh
# Creates the Ystervos add-on signing PKI, mirroring addons.mozilla.org's layout:
#   root CA (compiled into Ystervos) -> signing CA -> one end-entity cert per add-on (made by sign-xpi.py)
# and the Android keystore that signs the Ystervos APK.
#
# Usage: make-keys.sh <output-dir>
# Keep <output-dir> private. Only root-ca.pem is public; it goes into ystervos/certs/.
set -eu
tools="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: make-keys.sh <output-dir>}"
mkdir -p "$out"
cd "$out"
umask 077

cat > openssl.cnf <<'CNF'
[ req ]
distinguished_name = dn
prompt = no
[ dn ]
[ root_ext ]
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[ ca_ext ]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
CNF

# Root CA: RSA 4096, 25 years. This is the certificate Ystervos trusts.
openssl req -new -x509 -newkey rsa:4096 -nodes -sha384 -days 9131 \
  -subj "/O=Ystervos/OU=Ystervos Add-on Signing/CN=Ystervos Add-on Root CA" \
  -config openssl.cnf -extensions root_ext \
  -keyout root-ca.key -out root-ca.pem

# patch-apk.sh writes the root over Mozilla's add-on stage root in libxul.so, so it must be
# exactly that length (1608 bytes). Re-issue it at that size (same key and name).
python3 "$tools/fit-root.py" . 1608
rm -f root-ca.prev.pem

# Signing CA: RSA 4096, 15 years, signs the per-add-on certificates.
openssl req -new -newkey rsa:4096 -nodes -sha384 \
  -subj "/O=Ystervos/OU=Ystervos Add-on Signing/CN=Ystervos Add-on Signing CA" \
  -config openssl.cnf -keyout signing-ca.key -out signing-ca.csr
openssl x509 -req -in signing-ca.csr -CA root-ca.pem -CAkey root-ca.key -CAcreateserial \
  -sha384 -days 5479 -extfile openssl.cnf -extensions ca_ext -out signing-ca.pem
rm signing-ca.csr

# Android APK signing keystore for Ystervos itself.
pass=$(openssl rand -base64 24)
keytool -genkeypair -v -keystore ystervos-apk.jks -storetype PKCS12 -alias ystervos \
  -keyalg RSA -keysize 4096 -validity 10000 -storepass "$pass" -keypass "$pass" \
  -dname "CN=Ystervos, O=Ystervos" >/dev/null 2>&1
printf '%s\n' "$pass" > ystervos-apk.password

echo "Created in $out:"
ls -1
openssl x509 -in root-ca.pem -noout -subject -fingerprint -sha256
