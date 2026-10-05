# Ystervos

Ystervos is IronFox with three changes:

1. **Name:** the app is called "Ystervos" (launcher, about pages, settings text).
2. **Package ID:** `org.ystervos.browser`, so it installs next to IronFox instead of replacing it.
3. **Add-on trust:** Gecko trusts add-ons signed by the Ystervos add-on root CA, as well as
   Mozilla's AMO root. Signature enforcement stays on: unsigned add-ons are still rejected,
   and you don't need `xpinstall.signatures.required=false`.

The changes target IronFox **v157.0.0.1** (Firefox 157.0).

## Layout

| Path | What it is |
|---|---|
| `certs/ystervos-addons-root.pem` | Public root certificate that gets compiled into Ystervos |
| `patches/gecko-ystervos-trust-addon-root.patch` | Gecko patch: adds that root to `addonsPublicRoots` in `security/manager/ssl/moz.build` |
| `apply.sh` | Applies the rename, package ID and Gecko patch to an IronFox checkout |
| `rebrand-sources.sh` | Run at the end of IronFox's prebuild; renames "IronFox" in user-visible strings only |
| `build.sh` | Clones IronFox, applies the changes and builds a signed arm64 APK in IronFox's Docker image |
| `tools/make-keys.sh` | Creates the add-on signing PKI and the APK keystore |
| `tools/sign-xpi.py` | Signs an `.xpi` with your key, in the same PKCS#7 layout addons.mozilla.org uses |
| `tools/verify-xpi.py` | Checks an `.xpi` signature against a root, applying the same checks as Gecko |

## Keys

`tools/make-keys.sh <dir>` creates:

- `root-ca.key` / `root-ca.pem`: the root. Only the `.pem` is public; it's the file in `certs/`.
  You need the `.key` only to issue a new signing CA, so keep it offline.
- `signing-ca.key` / `signing-ca.pem`: an intermediate CA that `sign-xpi.py` uses. It issues a fresh
  certificate per add-on, with CN = add-on ID, which is what Firefox checks.
- `ystervos-apk.jks` / `ystervos-apk.password`: Android keystore (alias `ystervos`) that signs the APK.
  Every update must be signed with this same keystore, or Android refuses to install it over the old one.

None of these private files belong in git. If you lose `root-ca.key`, you need a new root, which means
rebuilding Ystervos.

## Signing an add-on

```sh
ystervos/tools/sign-xpi.py --keys <keys-dir> my-addon.xpi my-addon-signed.xpi
ystervos/tools/verify-xpi.py --root ystervos/certs/ystervos-addons-root.pem my-addon-signed.xpi
```

The add-on needs `browser_specific_settings.gecko.id` in its `manifest.json`.
The signature uses SHA-256, which IronFox's hardened settings require
(`xpinstall.signatures.weakSignaturesTemporarilyAllowed=false`).

Install it in Ystervos the same way as any `.xpi`: **Settings → About Ystervos**, tap the logo 5 times,
then **Settings → Install extension from file**.

## Building

On a Linux machine with Docker, about 80 GB of free disk and 16 GB of RAM:

```sh
ystervos/build.sh <keys-dir>            # builds IronFox v157.0.0.1 as Ystervos
```

The signed APK ends up in `ystervos-build/outputs/apk/`. Install it with `adb install` or by opening it on the phone.

To move to a newer IronFox release later, pass its tag as the second argument. `apply.sh` stops with an error
if anything it edits has changed upstream, rather than building something half-renamed.
