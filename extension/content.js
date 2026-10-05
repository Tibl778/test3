// HN Mark All Read: Firefox (desktop + Android) port of
// https://github.com/andreicristianpetcu/HNMarkAllRead (MIT, (c) 2012 Daniele Mazzini).
//
// State lives in browser.storage.local instead of the page's localStorage so it
// survives privacy-hardened browsers (e.g. IronFox) clearing site data.

(async function () {
  "use strict";

  const api = typeof browser !== "undefined" ? browser : chrome;
  const EXPIRY_MS = 4 * 24 * 60 * 60 * 1000; // forget entries after 4 days, like the original

  const KEYS = {
    stories: "read_stories",       // { itemId: timestamp }
    comments: "read_comments",     // { commentId: timestamp }
    followed: "followed_items",    // { itemId: { time, read_comments } }
    hideStories: "hide_read_stories",
    hideComments: "hide_read_comments",
  };

  // ---------------------------------------------------------------- storage

  const stored = await api.storage.local.get(Object.values(KEYS));
  const now = Date.now();

  function pruned(map, timeOf) {
    const out = {};
    for (const [k, v] of Object.entries(map || {})) {
      if (now - timeOf(v) <= EXPIRY_MS) out[k] = v;
    }
    return out;
  }

  const readStories = pruned(stored[KEYS.stories], (t) => t);
  const readComments = pruned(stored[KEYS.comments], (t) => t);
  const followed = pruned(stored[KEYS.followed], (f) => f.time);

  await api.storage.local.set({
    [KEYS.stories]: readStories,
    [KEYS.comments]: readComments,
    [KEYS.followed]: followed,
  });

  // Merge into the latest stored copy so two open tabs don't clobber each other.
  async function mergeInto(key, entries, removals = []) {
    const current = (await api.storage.local.get(key))[key] || {};
    Object.assign(current, entries);
    for (const k of removals) delete current[k];
    await api.storage.local.set({ [key]: current });
  }

  function setFlag(key, value) {
    return api.storage.local.set({ [key]: value });
  }

  // ---------------------------------------------------------------- helpers

  function el(tag, attrs = {}, children = []) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === "class") node.className = v;
      else if (k === "text") node.textContent = v;
      else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v);
    }
    for (const c of children) node.append(c);
    return node;
  }

  function button(label, title, onclick) {
    return el("a", {
      class: "hnmar_btn",
      href: "javascript:void(0)",
      role: "button",
      title,
      text: label,
      onclick: (e) => { e.preventDefault(); onclick(e); },
    });
  }

  function toggle(label, checked, onchange) {
    const input = el("input", { type: "checkbox" });
    input.checked = checked;
    input.addEventListener("change", () => onchange(input.checked));
    return el("label", { class: "hnmar_toggle" }, [input, " " + label]);
  }

  function setToggles(selector, checked) {
    for (const i of document.querySelectorAll(selector + " input")) i.checked = checked;
  }

  function countFrom(text) {
    const m = (text || "").replace(/ /g, " ").match(/(\d+)\s*comment/);
    return m ? parseInt(m[1], 10) : 0;
  }

  function commentsLink(subtext) {
    // The last "item?id=" link in the subtext is the comments/discuss link.
    const links = [...subtext.querySelectorAll('a[href^="item?id="]')];
    const last = links[links.length - 1];
    return last && /comment|discuss/i.test(last.textContent) ? last : null;
  }

  const params = new URLSearchParams(location.search);
  const isItemPage = location.pathname === "/item";

  if (isItemPage) setUpCommentsPage();
  else setUpListingPage();

  // ---------------------------------------------------------------- listings

  function setUpListingPage() {
    const rows = [...document.querySelectorAll("tr.athing.submission, tr.athing[id]:not(.comtr)")]
      .filter((tr) => tr.querySelector(".titleline"));
    if (rows.length === 0) return;

    document.body.classList.add("hnmar");
    document.body.classList.toggle("hnmar_hide_read", !!stored[KEYS.hideStories]);

    for (const tr of rows) {
      const id = tr.id;
      const subRow = tr.nextElementSibling;
      const spacer = subRow && subRow.nextElementSibling;
      const subtext = subRow && subRow.querySelector(".subtext");

      // Tag the rows of a story (title, subtext, spacer) so CSS can hide them together.
      const storyRows = [tr];
      if (subRow && !subRow.classList.contains("athing")) storyRows.push(subRow);
      if (spacer && spacer.classList.contains("spacer")) storyRows.push(spacer);
      for (const r of storyRows) r.classList.add("hnmar_story", "hnmar_story_" + id);

      const link = subtext && commentsLink(subtext);
      if (followed[id]) {
        for (const r of storyRows) r.classList.add("hnmar_following");
        if (link) {
          const total = countFrom(link.textContent);
          const unread = total - followed[id].read_comments;
          if (unread > 0) {
            link.textContent = `${unread} new / ${total} comments`;
            link.classList.add("hnmar_new_comments");
          }
        }
      }

      if (readStories[id]) markStoryRow(id);
    }

    const markAll = () => {
      const t = Date.now();
      const entries = {};
      for (const tr of rows) {
        if (!readStories[tr.id]) {
          entries[tr.id] = readStories[tr.id] = t;
          markStoryRow(tr.id);
        }
      }
      mergeInto(KEYS.stories, entries);
    };

    const onHide = (checked) => {
      document.body.classList.toggle("hnmar_hide_read", checked);
      setToggles(".hnmar_hide_stories", checked);
      setFlag(KEYS.hideStories, checked);
    };

    const bar = () => el("span", { class: "hnmar_bar" }, [
      button("✓ Mark all read", "Mark every story on this page as read", markAll),
      el("span", { class: "hnmar_hide_stories" }, [toggle("Hide read", !!stored[KEYS.hideStories], onHide)]),
    ]);

    const pagetop = document.querySelector(".pagetop");
    if (pagetop) pagetop.append(" ", bar());

    const more = document.querySelector("a.morelink");
    if (more) more.parentElement.append(" ", bar());
  }

  function markStoryRow(id) {
    for (const r of document.querySelectorAll(".hnmar_story_" + CSS.escape(id))) {
      r.classList.add("hnmar_read");
    }
  }

  // ---------------------------------------------------------------- comments

  function setUpCommentsPage() {
    const itemId = params.get("id");
    if (!itemId) return;

    const commentRows = [...document.querySelectorAll("tr.athing.comtr")];
    document.body.classList.add("hnmar");
    document.body.classList.toggle("hnmar_hide_read", !!stored[KEYS.hideComments]);

    // Build the tree from the indent level, mark read state.
    const stack = []; // stack[depth] = row
    let unread = 0;
    for (const tr of commentRows) {
      const ind = tr.querySelector("td.ind");
      let depth = ind ? parseInt(ind.getAttribute("indent"), 10) : NaN;
      if (Number.isNaN(depth)) {
        const img = ind && ind.querySelector("img");
        depth = img ? Math.round(img.width / 40) : 0;
      }
      tr.dataset.hnmarDepth = depth;
      stack.length = depth;
      const parent = depth > 0 ? stack[depth - 1] : null;
      stack[depth] = tr;
      if (parent) tr.hnmarParent = parent;
      if (depth > 0) tr.classList.add("hnmar_reply");

      if (readComments[tr.id]) tr.classList.add("hnmar_read");
      else { tr.classList.add("hnmar_unread"); unread++; }
    }

    // "show parent": useful when the parent is hidden because it was read.
    for (const tr of commentRows) {
      const parent = tr.hnmarParent;
      const comhead = tr.querySelector(".comhead");
      if (!parent || !comhead) continue;
      if (parent.classList.contains("hnmar_read")) tr.classList.add("hnmar_parent_read");
      let shown = null;
      comhead.append(el("span", { class: "hnmar_showparent_wrap" }, [
        " | ",
        button("show parent", "Show the parent comment inline", () => {
          if (shown) { shown.remove(); shown = null; return; }
          const src = parent.querySelector(".comment") || parent.querySelector("td.default");
          const head = parent.querySelector(".comhead .hnuser");
          shown = el("div", { class: "hnmar_parent_preview" }, [
            el("div", { class: "hnmar_parent_author", text: head ? head.textContent + " wrote:" : "Parent:" }),
          ]);
          const body = src.cloneNode(true);
          for (const r of body.querySelectorAll(".reply")) r.remove();
          shown.append(body);
          comhead.closest("td.default").querySelector(".comment").before(shown);
        }),
      ]));
    }

    const subtext = document.querySelector(".fatitem .subtext");
    const counterLink = subtext && commentsLink(subtext);
    const total = commentRows.length;
    const updateCounter = () => {
      if (counterLink) counterLink.textContent = `${unread} unread / ${total} comments`;
    };
    updateCounter();

    // Keep the follow record's read count current.
    const saveFollowed = () => {
      if (!followed[itemId]) return;
      followed[itemId].read_comments = total - unread;
      mergeInto(KEYS.followed, { [itemId]: followed[itemId] });
    };

    const markAll = () => {
      const t = Date.now();
      const entries = {};
      for (const tr of commentRows) {
        if (tr.classList.contains("hnmar_unread")) {
          entries[tr.id] = readComments[tr.id] = t;
          tr.classList.replace("hnmar_unread", "hnmar_read");
        }
        tr.classList.add("hnmar_parent_read");
      }
      for (const tr of commentRows) {
        if (!tr.hnmarParent) tr.classList.remove("hnmar_parent_read");
      }
      unread = 0;
      updateCounter();
      mergeInto(KEYS.comments, entries);
      saveFollowed();
    };

    const onHide = (checked) => {
      document.body.classList.toggle("hnmar_hide_read", checked);
      setToggles(".hnmar_hide_comments", checked);
      setFlag(KEYS.hideComments, checked);
    };

    const onFollow = (checked) => {
      setToggles(".hnmar_follow", checked);
      if (checked) {
        followed[itemId] = { time: Date.now(), read_comments: total - unread };
        mergeInto(KEYS.followed, { [itemId]: followed[itemId] });
      } else {
        delete followed[itemId];
        mergeInto(KEYS.followed, {}, [itemId]);
      }
    };

    const collapseAll = (collapsed) => document.body.classList.toggle("hnmar_collapsed", collapsed);

    const bar = () => el("div", { class: "hnmar_bar hnmar_bar_block" }, [
      button("✓ Mark all comments read", "Mark every comment on this page as read", markAll),
      el("span", { class: "hnmar_hide_comments" }, [toggle("Hide read", !!stored[KEYS.hideComments], onHide)]),
      el("span", { class: "hnmar_follow" }, [toggle("Follow", !!followed[itemId], onFollow)]),
      button("Top-level only", "Collapse all replies", () => collapseAll(true)),
      button("Expand all", "Show all replies", () => collapseAll(false)),
    ]);

    const fatitem = document.querySelector("table.fatitem");
    if (fatitem) fatitem.after(bar());
    const tree = document.querySelector("table.comment-tree");
    if (tree && commentRows.length > 0) tree.after(bar());
  }
})();
