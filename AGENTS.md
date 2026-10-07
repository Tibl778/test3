# AGENTS.md: how to rebuild this project

Instructions for an LLM coding agent (or a person) who needs to recreate, update or debug
everything in this repository. Read it fully before changing anything. Everything runs locally
through `./ystervos.sh`; GitHub is optional.

## What this project is

Three things that depend on each other:

1. **HN Mark All Read** (`extension/`): a Firefox for Android add-on. It's a rewrite of
   [andreicristianpetcu/HNMarkAllRead](https://github.com/andreicristianpetcu/HNMarkAllRead), a 2012–2016
   Chrome extension (MIT, © Daniele Mazzini) that no longer works against today's Hacker News.
2. **A personal add-on signing key** (`ystervos/tools/`): a small PKI in the same layout
   addons.mozilla.org (AMO) uses, so add-ons can be signed without Mozilla.
3. **Ystervos** (`ystervos/`): IronFox (a hardened Firefox for Android fork) renamed to "Ystervos"
   (Afrikaans for "iron fox"), installed as `org.ystervos.browser` next to IronFox, and made to trust
   add-ons signed with key 2 *in addition to* AMO-signed ones. Signature enforcement stays on.

The owner's goal: run the add-on in a browser they control, on their phone, with signatures enforced.

## Quick start

```sh
./ystervos.sh doctor          # bash curl python3 openssl java(17+) node npm; optional 7z/py7zr, adb
./ystervos.sh keys            # once: creates ~/.ystervos/keys and copies the public root into the repo
./ystervos.sh test            # 20 add-on tests in headless Chromium + web-ext lint
./ystervos.sh addon           # dist/hn-mark-all-read-ystervos-signed.xpi
./ystervos.sh apk             # out/ystervos-<ironfox-version>-arm64-v8a.apk (about 2 minutes)
./ystervos.sh split           # out/parts/*.7z.001… (each under 30 MB, for chat-style uploads)
./ystervos.sh install         # adb install + copy the .xpi to the phone's Download folder
./ystervos.sh update          # build only when IronFox has a new release
./ystervos.sh schedule        # run `update` daily (systemd user timer, else prints a cron line)
```

`YSTERVOS_KEYS`, `YSTERVOS_OUT` and `YSTERVOS_WORK` override the key, output and scratch paths.

**If the owner already has keys** (a `ystervos-keys.tar.gz` bundle), extract it and point
`YSTERVOS_KEYS` at the folder. Don't run `keys`: a new root means a new APK, and the installed
Ystervos would no longer trust newly signed add-ons.

## Repository layout

| Path | Role |
|---|---|
| `ystervos.sh` | The single entry point. Every other script is called from here. |
| `extension/` | The add-on: `manifest.json` (MV2), `content.js`, `styles.css`, `icons/icon.svg` |
| `test/` | `test.js` (Playwright, mock HN pages from `fixtures.js`, stubbed `browser.storage`), `package.json` |
| `dist/` | Built add-ons, committed so the owner can download them from GitHub |
| `ystervos/certs/ystervos-addons-root.pem` | Public root certificate, the one compiled/patched into Ystervos |
| `ystervos/tools/make-keys.sh` | Creates the PKI and the APK keystore |
| `ystervos/tools/fit-root.py` | Re-issues the root (same key) at an exact DER length |
| `ystervos/tools/sign-xpi.py` / `verify-xpi.py` | Signs an .xpi in AMO's layout / checks it as Gecko does |
| `ystervos/patch-apk.sh` + `tools/patch_apk.py` | Builds Ystervos by patching IronFox's release APK |
| `ystervos/tools/split-7z.py` | Splits the APK into small 7z volumes |
| `ystervos/apply.sh`, `build.sh`, `rebrand-sources.sh`, `patches/` | Alternative: full source build (hours, ~80 GB) |
| `ystervos/contrib/` | systemd unit + timer used by `./ystervos.sh schedule` |
| `.github/workflows/` | Optional CI: `test.yml` (tests on every push), `ystervos.yml` (APK build) |

## Part 1: the add-on

### Why it's a rewrite, not a port

The original uses jQuery 1.7, `chrome.extension.getURL`, and hard-coded DOM positions
(`sub.childNodes[9]`, `$("table")[2].nextSibling…`) that broke when HN changed its markup.
It's rewritten in plain JS against HN's current markup:

- Listing rows: `tr.athing.submission` (id = item id) with `.titleline > a`; the next `tr` holds `td.subtext`;
  then `tr.spacer`. The comments link is the last `a[href^="item?id="]` in the subtext whose text
  contains "comment" or "discuss". Job posts have no comments link. "More" is `a.morelink`.
- Item pages (`/item?id=`): `table.fatitem` for the story, `table.comment-tree` with `tr.athing.comtr`
  rows. Depth comes from `td.ind[indent]` (fallback: indent image width ÷ 40).
- HN has its own `[–]` collapse and "parent" links now, so the original's hover-only features were
  replaced with tap actions ("show parent" inline when the parent is hidden; "Top-level only"/"Expand all").

**HN may be unreachable from sandboxes.** `test/fixtures.js` reproduces the structure above. If HN changes,
update the fixtures from a real page first, then the selectors.

### Design decisions

- **Storage:** `browser.storage.local` (needs the `storage` permission), not the page's `localStorage`.
  IronFox defaults to "Delete browsing data on quit", which would wipe site storage. Writes merge
  with the stored copy (`mergeInto`) so two tabs don't overwrite each other. Entries expire after 4 days,
  as in the original.
- **Manifest:** MV2, so content scripts get host access without a runtime permission prompt.
  `browser_specific_settings.gecko.id = hn-mark-all-read@tibl778.github.io` (an ID is required for signing and
  becomes the certificate CN), `data_collection_permissions: {required: ["none"]}`, `strict_min_version`
  140 (desktop) / 142 (Android). With these values `web-ext lint` reports 0 errors and 0 warnings.
- **Touch UI:** pill buttons with a minimum height of 28px. Every selector is scoped under `body.hnmar`.
- **Split button** `[✓ Mark all read | + more]`: "+ more" awaits the storage write, then navigates to
  `a.morelink`'s href. It only renders when a More link exists.
- **New icon:** the original README asks forks to use their own artwork.

### Verify

`./ystervos.sh test` must report 20 PASS and lint must report 0 errors and 0 warnings. Add a test for
every new behavior.

## Part 2: the signing key and the .xpi signature format

### PKI (created by `make-keys.sh`)

- **Root CA:** RSA 4096, SHA-384, 25 years, `CA:true`, `keyCertSign, cRLSign`.
  **It must be exactly 1608 bytes in DER** (see Part 3); `fit-root.py` pads a non-critical
  `nsComment` extension until it is. Same key and subject, so re-issuing it keeps old signatures valid.
- **Signing CA:** RSA 4096, `pathlen:0`, EKU `codeSigning`. It mirrors AMO's intermediate, and
  `sign-xpi.py` uses it.
- **Per add-on certificate:** made fresh on every signing, RSA 4096, EKU `codeSigning`, KU `digitalSignature`,
  **CN = add-on ID** (SHA-256 hex of the ID if the ID is longer than 64 characters; that's what Gecko compares).
  OU is `Ystervos Extensions`. Never use `Mozilla Extensions` (privileged), `Mozilla Components` (system),
  or anything containing "preliminary".
- **APK keystore:** `ystervos-apk.jks` (PKCS12, alias `ystervos`, RSA 4096) plus `ystervos-apk.password`.
  Every Ystervos update must be signed with it, or Android refuses to update.

### Signature layout (matches AMO byte for byte, minus COSE)

- `META-INF/manifest.mf`: `Manifest-Version: 1.0`, then per file `Name:`, `Digest-Algorithms: SHA1 SHA256`,
  `SHA1-Digest:`, `SHA256-Digest:` (base64). Lines are wrapped at 72 bytes.
- `META-INF/mozilla.sf`: `Signature-Version: 1.0`, `SHA1-Digest-Manifest:`, `SHA256-Digest-Manifest:`.
- `META-INF/mozilla.rsa`: detached CMS over `mozilla.sf`, created with
  `openssl cms -sign -binary -md sha256 -nosmimecap -outform DER`. It includes the signer and signing CA certificates.
- No COSE: Gecko's default `security.signed_app_signatures.policy = 2` verifies COSE only if present.
- SHA-256 is mandatory in practice: IronFox (through Phoenix) sets
  `xpinstall.signatures.weakSignaturesTemporarilyAllowed=false`, and PKCS#7-with-SHA1 counts as weak.

This was validated by re-signing uBlock Origin's AMO-signed release: the generated `manifest.mf` was
identical to AMO's except AMO's two extra COSE entries. `verify-xpi.py` accepts the real AMO signature
against Mozilla's root and ours against our root, and rejects the cross-combinations and tampered files.

## Part 3: Ystervos by patching the release APK (the default path)

`patch-apk.sh` → `tools/patch_apk.py`. About 2 minutes, no compiling. Steps and the reasoning behind each:

1. **Download:** `https://gitlab.com/ironfox-oss/fdroid/-/raw/HEAD/fdroid/repo/ironfox-<v>-arm64-v8a.apk`,
   checked against the `.apk-sha512sum.txt` next to it. **IronFox's F-Droid repo keeps only the newest
   release**, so older versions disappear. The latest version comes from GitLab's
   `releases/permalink/latest`. (`releases.ironfoxoss.org` may be blocked from sandboxes; GitLab works.)
2. **Decode** with apktool 2.12.1.
3. **libxul.so:** overwrite every copy (there are 3) of Mozilla's add-on **stage** root certificate with
   the Ystervos root. The stage root is fetched from the exact Firefox commit the IronFox release is built
   on (`IRONFOX_GECKO_COMMIT` in IronFox's `scripts/versions.sh` at the release tag). Equal length is
   required, which is why the root is 1608 bytes. The production AMO root is untouched.
4. **omni.ja `modules/addons/XPIInstall.sys.mjs`** (minified): replace `verifySignedState` so it checks the
   AMO root first and, only when the result is `SIGNEDSTATE_UNKNOWN` (no chain to AMO), checks the stage
   slot. `MISSING` (unsigned) and `BROKEN` (tampered) stay rejected. The match is a strict regex (`VERIFY_RE`)
   that fails loudly when IronFox changes the code. A `node --check` confirms the result parses.
   (IronFox is built with `MOZ_REQUIRE_SIGNING = false`, but the stock `xpinstall.signatures.dev-root` pref
   would switch to the stage root *only*, which would break AMO add-ons; hence the fallback.)
5. **Brand:** in `omni.ja`, replace "IronFox" with "Ystervos" in `.ftl`/`.properties` text (comment lines are
   left alone). In `res/values*/strings*.xml`, replace only in text nodes, never in names or attributes.
6. **Package ID:** replace `org.ironfoxoss.ironfox` with `org.ystervos.browser` everywhere in `AndroidManifest.xml`
   (38 references: package, providers, permissions, launcher aliases, sharedUserId), in `res/xml/shortcuts.xml`,
   and in the single smali `const-string "org.ironfoxoss.ironfox"` (the inlined `BuildConfig.APPLICATION_ID`).
   Java/Kotlin class names (`org.ironfoxoss.ironfox.utils.*`) are left alone. The package ID is not in libxul.
7. **Rebuild** with apktool, then zipalign + sign (v2 + v3) with uber-apk-signer 1.3.0 and the APK keystore.

Expected `patch_apk.py` output for 157.0.1: `libxul: replaced 3 copies`, `brand text in 160 files`,
`manifest: 38 references`, `code: 1 package-ID constants`, `strings: … in 113 files`.
If a count changes a lot on a new release, inspect before shipping.

### Alternative: full source build

`ystervos/build.sh <keys>` clones IronFox at a tag, runs `apply.sh` (rename, package ID, and the Gecko patch
`patches/gecko-ystervos-trust-addon-root.patch`, which adds the root to `addonsPublicRoots` in
`security/manager/ssl/moz.build`), then IronFox's Docker build. It needs about 80 GB of disk, 16 GB of RAM, hours of
build time, and access to Mozilla/Google servers. **It has never been run end to end;** only the patch application
was tested. Regenerate the Gecko patch whenever the root changes (it embeds the PEM).

## Part 4: installing on the phone

These steps were verified against the decompiled 157.0.1 app; earlier guesses were wrong, so don't simplify them:

1. Install the APK. It sits next to IronFox (different package) and keeps its own data.
2. **Settings → Ystervos settings → Security → "Allow installation of add-ons"** (default **off**). This is
   IronFox's own switch (`pref_key_xpinstall_enabled`); while it's off, the install-from-file option is hidden.
   Turning it on restarts the app.
3. **Settings → About Ystervos → tap the logo 5 times** ("Debug menu enabled"). The flag
   `showSecretDebugMenuThisSession` lives in memory only, so every app restart clears it.
4. **Settings → Advanced → "Install extension from file"** (directly below Extensions) → pick the signed `.xpi`.

The option is visible only when both 2 and 3 are true (`SettingsFragment.onResume`).
`./ystervos.sh install` does the adb part and prints these steps.

## Keeping it up to date

- `./ystervos.sh update` (or `schedule` for daily runs) rebuilds when IronFox releases. Install the new APK over
  the old one; data stays because the package and signing key are the same.
- Things most likely to break on a new IronFox/Firefox release, in order: `VERIFY_RE` in `patch_apk.py`;
  the stage root length (it must stay 1608, else re-issue with `fit-root.py <keys> <length>`, then re-sign add-ons);
  apktool compatibility (bump the version in `patch-apk.sh`); the xpinstall/debug-menu gating in Part 4.
- Add-on changes: edit `extension/`, bump `version` in `manifest.json`, `./ystervos.sh test && ./ystervos.sh addon`,
  commit `dist/`.

## Constraints learned in cloud sandboxes (Claude Code on the web)

These cost a lot of time; check them first if the agent runs in a sandbox:

- **Network:** `hg.mozilla.org`, `archive.mozilla.org`, `dl.google.com`, `maven.mozilla.org`,
  `releases.ironfoxoss.org` and `news.ycombinator.com` were blocked. `gitlab.com`, `raw.githubusercontent.com`,
  GitHub release downloads, PyPI, npm and Maven Central worked. That's why the APK patch path exists: the
  source build can't run there, and 30 GB of disk is too little anyway.
- **Delivering large files:** chat file transfer is capped at 30 MB (`./ystervos.sh split`); claude.ai artifact pages
  don't serve archives or binaries; pushes containing large binaries were rejected by the git proxy (even 9 MB
  pieces); Git LFS uploads returned 403. The GitHub Actions *secrets* API is blocked, so the owner must add
  `YSTERVOS_APK_KEYSTORE` (base64 of the .jks) and `YSTERVOS_APK_KEYSTORE_PASSWORD` themselves if they want CI APK
  builds.
- **Permission checks:** an automated safety check may block creating or patching a trusted root. That needs the
  owner's explicit approval (in Claude Code on the web: switch the mode dropdown from Auto to "Accept edits"
  so commands go to them). Never try to route around such a block.
- **No access to the phone.** The agent can't install or tap anything. Give exact, verified steps instead.

## Security notes

- The private keys (`root-ca.key`, `signing-ca.key`, `ystervos-apk.jks`, `ystervos-apk.password`) never go in git
  (`.gitignore` covers them). Only the APK keystore may be stored as a CI secret; the add-on keys stay offline.
- Anyone with the signing CA key can sign add-ons that Ystervos will install. Anyone with the APK keystore can
  ship an update over Ystervos.
- The patched APK is a modified binary, not a reproducible build. The SHA-512 check on IronFox's original and the
  logged patch counts are the audit trail.
