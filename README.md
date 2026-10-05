# HN Mark All Read for Firefox for Android

A port of [HNMarkAllRead](https://github.com/andreicristianpetcu/HNMarkAllRead) (Daniele Mazzini's
Chrome extension) to Firefox for Android and its forks, such as IronFox. It also runs on desktop Firefox.

## Features

On listing pages (front page, new, past, ask, show…):
- **✓ Mark all read** greys out every story on the page. It shows in the header and next to "More".
- **Hide read** hides stories you've marked read.
- Stories you follow are shown in purple, with a green **N new / M comments** link when there are new comments.

On a story's comments page:
- An **N unread / M comments** counter replaces the comment count.
- **✓ Mark all comments read** gives read comments a grey background.
- **Hide read** hides read comments. When a comment's parent is hidden, a **show parent** link shows the parent inline.
- **Follow** tracks the thread's comment count so the front page can flag new comments.
- **Top-level only** and **Expand all** collapse or expand all replies. HN's own `[–]` toggles still work too.

Everything is forgotten after 4 days, like in the original.

## Changes from the original

- Rewritten in plain JavaScript (no jQuery 1.7) against HN's current markup (`span.titleline`, `td.ind[indent]`,
  `table.comment-tree`, …). The original's hard-coded DOM indexes stopped matching years ago.
- State is kept in `browser.storage.local` instead of HN's `localStorage`, so it survives IronFox
  clearing site data. Writes merge with what is stored, so two open tabs don't overwrite each other.
- Touch-sized buttons. Hover-only features ("show parent" on hover, the left-margin collapse handles) were
  replaced with tap actions.
- New icon, as the original README asks for forks.

## Install in IronFox (Android)

The XPI is unsigned, so IronFox needs to be told to accept unsigned add-ons first:

1. Get `dist/hn-mark-all-read.xpi` onto the phone (download it from this repo or rebuild it with `./build.sh`).
2. In IronFox, open `about:config`, search for `xpinstall.signatures.required`, and set it to **false**.
3. Open **Settings → About IronFox** and tap the IronFox logo 5 times to turn on the debug menu.
4. Go back to **Settings** and open **Install extension from file** (it's near the bottom, under Advanced).
   Pick `hn-mark-all-read.xpi` and confirm.
5. Open https://news.ycombinator.com.

If IronFox still rejects the file as "corrupt" or "unverified", the other route is to sign it as an unlisted
add-on on addons.mozilla.org (`web-ext sign --channel=unlisted`, which needs an AMO API key). A signed XPI
installs with step 4 alone.

## Build

```sh
./build.sh   # writes dist/hn-mark-all-read.xpi
```

## License

MIT. Original code © 2012 Daniele Mazzini. See [LICENSE](LICENSE).
