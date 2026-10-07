// Runs content.js against mock HN pages in headless Chromium with a stubbed browser.storage.
// Usage: npm i playwright-core && node test/test.js
const { chromium } = require('playwright-core');
const fs = require('fs');
const fx = require('./fixtures');
const EXT = require('path').join(__dirname, '../extension/');
const js = fs.readFileSync(EXT + 'content.js', 'utf8'), css = fs.readFileSync(EXT + 'styles.css', 'utf8');
const stub = `window.__store = JSON.parse(sessionStorage.getItem('__store') || '{}');
window.browser = { storage: { local: {
  get: async (keys) => { const ks = Array.isArray(keys) ? keys : [keys]; const o = {}; for (const k of ks) if (k in __store) o[k] = JSON.parse(JSON.stringify(__store[k])); return o; },
  set: async (obj) => { Object.assign(__store, JSON.parse(JSON.stringify(obj))); sessionStorage.setItem('__store', JSON.stringify(__store)); } } } };`;
let fails = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fails++; };
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' }).catch(() => chromium.launch());
  const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  await ctx.route('https://news.ycombinator.com/**', r => {
    const u = new URL(r.request().url());
    if (u.pathname === '/news' || u.pathname === '/news/' || u.pathname === '/') return r.fulfill({ contentType: 'text/html', body: fx.front });
    if (u.pathname === '/item') return r.fulfill({ contentType: 'text/html', body: fx.item });
    return r.fulfill({ status: 404, body: '' });
  });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(e.message));
  const load = async (url) => { await page.goto(url); await page.evaluate(stub); await page.addStyleTag({ content: css }); await page.evaluate(js); await page.waitForTimeout(100); };
  const vis = (sel) => page.$eval(sel, e => getComputedStyle(e).display !== 'none' && e.getClientRects().length > 0);

  await load('https://news.ycombinator.com/news');
  ok(await page.$$eval('.hnmar_bar', a => a.length) === 2, 'two control bars on front page');
  await page.screenshot({ path: '/tmp/front-before.png', fullPage: true });
  await page.click('.pagetop .hnmar_btn');
  ok(await page.$eval('[id="101"] .titleline > a', e => getComputedStyle(e).color) === 'rgb(130, 130, 130)', 'story greyed after mark all');
  ok(Object.keys((await page.evaluate(() => __store)).read_stories).length === 4, 'four stories stored (incl. job)');
  await page.click('.pagetop .hnmar_toggle input');
  ok(!(await vis('[id="101"]')), 'read story hidden with Hide read');
  ok(await page.$$eval('.hnmar_hide_stories input', a => a.every(i => i.checked)), 'both toggles synced');

  // comments page
  await load('https://news.ycombinator.com/item?id=101');
  ok(await page.$eval('.fatitem .subtext', e => [...e.querySelectorAll('a')].pop().textContent) === '4 unread / 4 comments', 'unread counter');
  await page.click('.hnmar_follow input');
  ok((await page.evaluate(() => __store)).followed_items['101'].read_comments === 0, 'follow stored');
  await page.screenshot({ path: '/tmp/item-before.png', fullPage: true });
  await page.click('.hnmar_bar_block .hnmar_btn');
  ok(await page.$eval('.fatitem .subtext', e => [...e.querySelectorAll('a')].pop().textContent) === '0 unread / 4 comments', 'counter after mark all');
  ok((await page.evaluate(() => __store)).followed_items['101'].read_comments === 4, 'follow count updated');
  await page.click('text=Top-level only');
  ok(!(await vis('[id="202"]')) && await vis('[id="201"]'), 'collapse hides replies');
  await page.click('text=Expand all');
  ok(await vis('[id="203"]'), 'expand all');

  // reload: comments read; simulate 2 new ones by clearing one id
  await page.evaluate(() => { delete __store.read_comments['203']; sessionStorage.setItem('__store', JSON.stringify(__store)); });
  await load('https://news.ycombinator.com/item?id=101');
  await page.click('.hnmar_hide_comments input');
  ok(!(await vis('[id="201"]')) && !(await vis('[id="202"]')) && await vis('[id="203"]'), 'hide read leaves only unread 203');
  ok(await vis('[id="203"] .hnmar_showparent_wrap'), 'show parent offered when parent hidden');
  await page.click('[id="203"] .hnmar_showparent_wrap .hnmar_btn');
  ok((await page.$eval('[id="203"] .hnmar_parent_preview', e => e.textContent)).includes('Reply to alice'), 'parent preview shows bob comment');
  await page.screenshot({ path: '/tmp/item-hidden.png', fullPage: true });

  // front page shows followed unread comments
  await page.evaluate(() => { __store.followed_items['101'].read_comments = 10; sessionStorage.setItem('__store', JSON.stringify(__store)); });
  await load('https://news.ycombinator.com/news');
  ok(await page.$eval('[id="101"] + tr .hnmar_new_comments', e => e.textContent) === '2 new / 12 comments', 'followed new comments on front');
  ok(await vis('[id="101"]') && !(await vis('[id="102"]')), 'followed story stays visible when hiding read');
  await page.screenshot({ path: '/tmp/front-after.png', fullPage: true });
  // "+ more" split button: marks the page read, then opens the next page.
  await page.evaluate(() => { __store = {}; sessionStorage.setItem('__store', '{}'); });
  await load('https://news.ycombinator.com/news');
  ok(await page.$$eval('.hnmar_split', a => a.length) === 2, 'split button in header and near More');
  await page.screenshot({ path: '/tmp/front-split.png' });
  await Promise.all([page.waitForURL('**/news?p=2'), page.click('.pagetop .hnmar_split .hnmar_btn:last-child')]);
  ok(Object.keys((await page.evaluate(() => JSON.parse(sessionStorage.getItem('__store') || '{}'))).read_stories || {}).length === 4, '+ more stored all four stories before leaving');
  ok(page.url().endsWith('/news?p=2'), '+ more opened the next page');
  ok(errs.length === 0, 'no page errors ' + errs.join(';'));
  await b.close();
  process.exit(fails ? 1 : 0);
})();
