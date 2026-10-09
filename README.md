# HN Mark All Read + Ystervos

- **HN Mark All Read:** a Firefox for Android add-on that marks Hacker News stories and comments as read.
  It's a rewrite of [HNMarkAllRead](https://github.com/andreicristianpetcu/HNMarkAllRead).
- **Ystervos:** IronFox renamed, installable next to IronFox, and set up to trust add-ons signed with your own key.
  Signature checks stay on.

Everything runs on your own Linux machine through one script (macOS works with GNU coreutils installed). GitHub is optional.
For the full technical story, aimed at an LLM rebuilding this project, read [AGENTS.md](AGENTS.md).

## Quick start

```sh
./ystervos.sh doctor      # checks for bash, curl, python3, openssl, Java 17+, node/npm
./ystervos.sh keys        # once: creates your keys in ~/.ystervos/keys (back them up)
./ystervos.sh all         # tests, signed add-on, Ystervos APK, split parts
./ystervos.sh install     # with the phone on USB (adb): installs the APK, copies the add-on
./ystervos.sh schedule    # rebuild automatically when IronFox releases
```

Already have a keys bundle? Extract it and run commands with `YSTERVOS_KEYS=/path/to/ystervos-keys`.
Run `./ystervos.sh help` for every command.

| Output | Where |
|---|---|
| Signed add-on | `dist/hn-mark-all-read-ystervos-signed.xpi` |
| Ystervos APK (arm64) | `out/ystervos-<version>-arm64-v8a.apk` |
| APK split into parts under 30 MB | `out/parts/` |

## Installing on the phone

1. Install the Ystervos APK.
2. **Settings → Ystervos settings → Security → Allow installation of add-ons** (the app restarts).
3. **Settings → About Ystervos**, then tap the logo 5 times ("Debug menu enabled"). This resets on every restart.
4. **Settings → Advanced → Install extension from file**, and pick the signed `.xpi`.

The latest signed add-on is also in this repo:
[dist/hn-mark-all-read-ystervos-signed.xpi](dist/hn-mark-all-read-ystervos-signed.xpi).

## Features

On listing pages (front page, new, past, ask, show…):
- **✓ Mark all read** greys out every story on the page. It shows in the header and next to "More".
- **+ more**, attached to that button, marks the page read and opens the next page.
- **Hide read** hides stories you've marked read.
- Stories you follow are shown in purple, with a green **N new / M comments** link when there are new comments.

On a story's comments page:
- An **N unread / M comments** counter replaces the comment count.
- **✓ Mark all comments read** gives read comments a grey background.
- **Hide read** hides read comments. When a comment's parent is hidden, a **show parent** link shows the parent inline.
- **Follow** tracks the thread's comment count so the front page can flag new comments.
- **Top-level only** and **Expand all** collapse or expand all replies. HN's own `[–]` toggles still work too.

Everything is forgotten after 4 days, like in the original.

## Changes from the original add-on

- Rewritten in plain JavaScript for HN's current markup; the original's hard-coded page positions stopped working years ago.
- Saves to the add-on's own storage, so IronFox clearing site data doesn't erase what you've read.
- Buttons sized for touch; hover-only features became tap actions.
- New icon, as the original README asks of forks.

## GitHub (optional)

- `.github/workflows/test.yml` runs `./ystervos.sh test` on every push.
- `.github/workflows/ystervos.yml` builds the APK on GitHub. It needs two repository secrets you add yourself:
  `YSTERVOS_APK_KEYSTORE` (base64 of `ystervos-apk.jks`) and `YSTERVOS_APK_KEYSTORE_PASSWORD`.

## License

MIT. The original add-on code is © 2012 Daniele Mazzini; see [LICENSE](LICENSE).
Ystervos is built from [IronFox](https://gitlab.com/ironfox-oss/IronFox), which has its own licenses.
