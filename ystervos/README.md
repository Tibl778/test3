# Ystervos

Ystervos is IronFox with three changes:

1. **Name:** the app is called "Ystervos" (launcher, about pages, settings text).
2. **Package ID:** `org.ystervos.browser`, so it installs next to IronFox instead of replacing it.
3. **Add-on trust:** Gecko trusts add-ons signed by the Ystervos add-on root CA, as well as
   Mozilla's AMO root. Signature enforcement stays on: unsigned add-ons are still rejected,
   and you don't need `xpinstall.signatures.required=false`.

There are two ways to make it:

- **`patch-apk.sh` (quick, about 2 minutes):** patches IronFox's official release APK. Nothing is compiled.
- **`build.sh` (full source build, hours):** builds IronFox from source with the changes applied as patches.

## Layout

| Path | What it is |
|---|---|
| `certs/ystervos-addons-root.pem` | Public root certificate that gets compiled into Ystervos |
| `patches/gecko-ystervos-trust-addon-root.patch` | Gecko patch: adds that root to `addonsPublicRoots` in `security/manager/ssl/moz.build` |
| `apply.sh` | Applies the rename, package ID and Gecko patch to an IronFox checkout |
| `rebrand-sources.sh` | Run at the end of IronFox's prebuild; renames "IronFox" in user-visible strings only |
| `patch-apk.sh` | Downloads IronFox's latest release APK, checks its SHA-512, patches it and signs it with your keystore |
| `tools/patch_apk.py` | The patch steps `patch-apk.sh` applies (see below) |
| `tools/fit-root.py` | Re-issues the root (same key) at the byte length `patch-apk.sh` needs |
| `build.sh` | Clones IronFox, applies the changes and builds a signed arm64 APK in IronFox's Docker image |
| `tools/make-keys.sh` | Creates the add-on signing PKI and the APK keystore |
| `tools/sign-xpi.py` | Signs an `.xpi` with your key, in the same PKCS#7 layout addons.mozilla.org uses |
| `tools/verify-xpi.py` | Checks an `.xpi` signature against a root, applying the same checks as Gecko |

## Keys

`tools/make-keys.sh <dir>` creates:

- `root-ca.key` / `root-ca.pem`: the root (re-issued at exactly 1608 bytes so `patch-apk.sh` can use it). Only the `.pem` is public; it's the file in `certs/`.
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

## Making the APK from the official release

```sh
ystervos/patch-apk.sh <keys-dir>             # latest IronFox release
ystervos/patch-apk.sh <keys-dir> 157.0.1     # a specific release (must still be in IronFox's F-Droid repo)
```

Needs curl, python3, openssl and Java 17+. The result is `ystervos-build/ystervos-<version>-arm64-v8a.apk`.
What it changes in the release:

- **`libxul.so`:** Mozilla's add-on *stage* root certificate (a test root that release builds don't use)
  is overwritten with the Ystervos root. Both are 1608 bytes, so nothing else in the library moves.
  Mozilla's production AMO root is untouched.
- **`omni.ja`** (`XPIInstall.sys.mjs`): add-ons are checked against the AMO root first. Only when the
  signature doesn't chain to AMO is the stage slot (now your root) tried. Unsigned and tampered add-ons are
  still rejected. The brand names in `.ftl`/`.properties` files say Ystervos.
- **App:** package ID `org.ystervos.browser` (manifest, launcher shortcuts and the one package-ID constant in
  the code), and "Ystervos" in the user-visible strings of every language.
- **Signature:** zipaligned and signed (v2 + v3) with `ystervos-apk.jks`.

To update, run it again when IronFox releases, then install the new APK over the old one.
Your data stays, because it's the same package and the same signing key.
If a release changes something the patcher expects, it stops with an error instead of producing a half-patched APK.

## Building on GitHub Actions

`.github/workflows/ystervos.yml` runs `patch-apk.sh` on GitHub and uploads the APK as a workflow artifact
(kept 90 days). Once the workflow is on the default branch, it also checks daily and builds only when IronFox
has a new release. You can start a build by hand from the Actions tab (**Run workflow**).

It needs two repository secrets (**Settings → Secrets and variables → Actions**):

| Secret | Value |
|---|---|
| `YSTERVOS_APK_KEYSTORE` | `base64 -w0 ystervos-apk.jks` |
| `YSTERVOS_APK_KEYSTORE_PASSWORD` | contents of `ystervos-apk.password` |

Only the APK keystore goes to GitHub. The add-on signing keys (`root-ca.key`, `signing-ca.key`) stay with you;
the build uses the public root certificate in `certs/`.

## Building from source

On a Linux machine with Docker, about 80 GB of free disk and 16 GB of RAM:

```sh
ystervos/build.sh <keys-dir>            # builds IronFox v157.0.0.1 as Ystervos
```

The signed APK ends up in `ystervos-build/outputs/apk/`. Install it with `adb install` or by opening it on the phone.

To move to a newer IronFox release later, pass its tag as the second argument. `apply.sh` stops with an error
if anything it edits has changed upstream, rather than building something half-renamed.
