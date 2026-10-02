// Tests for the app-update mechanism (roadmap tasks 4-8): popup, red dot, offline, service worker rules, install prompt.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs'), path = require('path');

const ROOT = path.resolve(__dirname, '..');
const swVersion = Number((fs.readFileSync(path.join(ROOT, 'sw.js'), 'utf8').match(/CACHE_VERSION\s*=\s*'dawam-attendance-v(\d+)'/) || [])[1]);

(async () => {
  const { srv, url, setDown } = await startServer();
  const goOffline = async (ctx) => { await ctx.setOffline(true); setDown(true); };   // page offline AND the server unreachable (service worker requests too)
  const goOnline = async (ctx) => { await ctx.setOffline(false); setDown(false); };
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined });
  const open = async (pagePath, { mock = true, ctxOpts = {}, waitSw = false } = {}) => {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, ...ctxOpts });
    await curlRoutes(ctx, /jsdelivr|supabase\.co/);
    await ctx.route(/justadudewhohacks/, r => r.abort());          // big face models: not needed here
    const page = await ctx.newPage();
    if (mock) await page.addInitScript(() => {
      const real = window.fetch.bind(window);
      window.__srv = { version: null, fail: false, calls: 0 };
      window.fetch = (u, o) => {
        if (String(u).includes('/sw.js?check=')) {
          window.__srv.calls++;
          if (window.__srv.fail) return Promise.reject(new TypeError('network down'));
          if (window.__srv.version) return Promise.resolve(new Response("const CACHE_VERSION = 'dawam-attendance-v" + window.__srv.version + "';"));
        }
        return real(u, o);
      };
    });
    await page.goto(url + pagePath);
    await page.waitForFunction(() => window.DawamUpdate && document.getElementById('dawamUpdateBtn'));
    if (waitSw) {
      await page.evaluate(() => navigator.serviceWorker.ready);
      await page.waitForFunction(async () => (await caches.keys()).length > 0 && !!(await caches.keys().then(k => caches.open(k[0]).then(c => c.keys()))).length, null, { timeout: 30000 });
      await page.reload();                                          // now controlled by the service worker
      await page.waitForFunction(() => window.DawamUpdate && navigator.serviceWorker.controller);
    }
    return { ctx, page };
  };
  const popupOpen = (page) => page.evaluate(() => document.getElementById('dawamUpdateModal').classList.contains('open'));
  const dotVisible = (page) => page.evaluate(() => !document.getElementById('dawamUpdateDot').hidden);
  const setServer = (page, v) => page.evaluate(v => { window.__srv.version = v; window.__srv.fail = false; }, v);

  console.log('Version numbers');
  await test(`running version is read from the script tag (v${swVersion}, same as sw.js)`, async () => {
    const { ctx, page } = await open('/index.html');
    eq(await page.evaluate(() => DawamUpdate.runningVersion()), swVersion);
    await ctx.close();
  });
  await test('against the real sw.js on the server: up to date, no red dot, no popup', async () => {
    const { ctx, page } = await open('/index.html', { mock: false });
    eq(await page.evaluate(() => DawamUpdate.check({ popup: true })), 'current');
    eq([await dotVisible(page), await popupOpen(page)], [false, false]);
    await ctx.close();
  });

  console.log('\nNew version found');
  await test('newer server version lights the red dot; a plain manual check does not open the popup', async () => {
    const { ctx, page } = await open('/index.html'); await setServer(page, swVersion + 5);
    eq(await page.evaluate(() => DawamUpdate.check()), 'newer');
    eq([await dotVisible(page), await popupOpen(page)], [true, false]);
    await ctx.close();
  });
  await test('automatic check opens a CENTRED popup with the new number and an Update now button; Later closes it, dot stays', async () => {
    const { ctx, page } = await open('/index.html'); await setServer(page, swVersion + 5);
    await page.evaluate(() => DawamUpdate.check({ popup: true }));
    eq(await popupOpen(page), true, 'popup open');
    const box = await page.locator('.dawam-upd-box').boundingBox(), vp = page.viewportSize();
    const cy = box.y + box.height / 2, cx = box.x + box.width / 2;
    ok(Math.abs(cy - vp.height / 2) < vp.height * 0.15 && Math.abs(cx - vp.width / 2) < vp.width * 0.1, `popup centre (${Math.round(cx)},${Math.round(cy)}) should be near the middle of ${vp.width}x${vp.height}`);
    ok((await page.locator('#dawamUpdateText').innerText()).includes('v' + (swVersion + 5)), 'new version number in the text');
    eq(await page.locator('#dawamUpdateNow').isVisible(), true, 'Update now visible');
    eq(await page.locator('#dawamUpdateLater').innerText(), 'Later');
    await page.click('#dawamUpdateLater');
    eq([await popupOpen(page), await dotVisible(page)], [false, true], 'closed, dot stays');
    await page.click('#dawamUpdateBtn');                      // tapping the icon with an update waiting re-opens it
    eq(await popupOpen(page), true, 're-opened');
    await ctx.close();
  });
  await test('an automatic check does NOT open the popup while another window is open (dot only)', async () => {
    const { ctx, page } = await open('/index.html'); await setServer(page, swVersion + 5);
    await page.evaluate(() => { const d = document.createElement('div'); d.className = 'modal-overlay active'; document.body.appendChild(d); });
    await page.evaluate(() => DawamUpdate.check({ popup: true }));
    eq([await popupOpen(page), await dotVisible(page)], [false, true]);
    await ctx.close();
  });
  await test('an automatic check does NOT open the popup while the page says it is busy (e.g. a punch in progress)', async () => {
    const { ctx, page } = await open('/index.html'); await setServer(page, swVersion + 5);
    await page.evaluate(() => { DawamUpdate.isBusy = () => true; });
    await page.evaluate(() => DawamUpdate.check({ popup: true }));
    eq([await popupOpen(page), await dotVisible(page)], [false, true]);
    await ctx.close();
  });
  await test('it opens by itself about 4 seconds after the page opens', async () => {
    const { ctx, page } = await open('/index.html'); await setServer(page, swVersion + 5);
    await page.waitForFunction(() => document.getElementById('dawamUpdateModal').classList.contains('open'), null, { timeout: 8000 });
    await ctx.close();
  });

  console.log('\nNo update / problems');
  await test('same version again clears the red dot', async () => {
    const { ctx, page } = await open('/index.html'); await setServer(page, swVersion + 5);
    await page.evaluate(() => DawamUpdate.check());
    eq(await dotVisible(page), true);
    await setServer(page, swVersion);
    eq(await page.evaluate(() => DawamUpdate.check()), 'current');
    eq(await dotVisible(page), false);
    await ctx.close();
  });
  await test('a failed check is harmless: "unknown", no dot, no popup', async () => {
    const { ctx, page } = await open('/index.html');
    await page.evaluate(() => { window.__srv.fail = true; });
    eq(await page.evaluate(() => DawamUpdate.check({ popup: true })), 'unknown');
    eq([await dotVisible(page), await popupOpen(page)], [false, false]);
    await ctx.close();
  });
  await test('offline: no check is made', async () => {
    const { ctx, page } = await open('/index.html');
    await ctx.setOffline(true);
    const before = await page.evaluate(() => window.__srv.calls);
    eq(await page.evaluate(() => DawamUpdate.check({ popup: true })), 'offline');
    eq(await page.evaluate(() => window.__srv.calls), before, 'no request made');
    await ctx.close();
  });
  await test('tapping the icon when up to date shows "latest version" and the running version', async () => {
    const { ctx, page } = await open('/index.html'); await setServer(page, swVersion);
    await page.click('#dawamUpdateBtn');
    await page.waitForFunction(() => document.getElementById('dawamUpdateText').textContent.includes('latest version'));
    eq(await page.locator('#dawamUpdateVer').innerText(), 'v' + swVersion);
    eq(await page.locator('#dawamUpdateNow').isVisible(), false, 'no Update now button');
    eq(await page.locator('#dawamUpdateLater').innerText(), 'OK');
    await ctx.close();
  });
  await test('tapping the icon offline shows the offline message', async () => {
    const { ctx, page } = await open('/index.html'); await ctx.setOffline(true);
    await page.click('#dawamUpdateBtn');
    await page.waitForFunction(() => document.getElementById('dawamUpdateText').textContent.includes('offline'));
    await ctx.close();
  });
  await test('coming back to the foreground after 5+ minutes checks again; the connection returning checks again', async () => {
    const { ctx, page } = await open('/index.html'); await setServer(page, swVersion);
    const c0 = await page.evaluate(() => window.__srv.calls);
    await page.evaluate(() => { DawamUpdate._state.lastCheck = Date.now() - 6 * 60000; document.dispatchEvent(new Event('visibilitychange')); });
    await page.waitForFunction(c => window.__srv.calls > c, c0);
    const c1 = await page.evaluate(() => window.__srv.calls);
    await page.evaluate(() => window.dispatchEvent(new Event('online')));
    await page.waitForFunction(c => window.__srv.calls > c, c1, { timeout: 6000 });
    await ctx.close();
  });

  console.log('\nUpdate now');
  await test('clearing app caches removes service workers and caches, keeps localStorage and IndexedDB', async () => {
    const { ctx, page } = await open('/index.html', { waitSw: true });
    await page.evaluate(async () => {
      localStorage.setItem('keep_me', 'yes');
      await new Promise((res, rej) => { const r = indexedDB.open('keepdb', 1); r.onupgradeneeded = () => r.result.createObjectStore('s'); r.onsuccess = () => { const t = r.result.transaction('s', 'readwrite'); t.objectStore('s').put('v', 'k'); t.oncomplete = () => res(); }; r.onerror = rej; });
    });
    ok((await page.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).length)) >= 1, 'a service worker is registered first');
    await page.evaluate(() => DawamUpdate._clearAppCaches());
    eq(await page.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).length), 0, 'registrations');
    eq(await page.evaluate(async () => (await caches.keys()).length), 0, 'caches');
    eq(await page.evaluate(() => localStorage.getItem('keep_me')), 'yes', 'localStorage');
    eq(await page.evaluate(() => new Promise(res => { const r = indexedDB.open('keepdb'); r.onsuccess = () => { const q = r.result.transaction('s').objectStore('s').get('k'); q.onsuccess = () => res(q.result); }; })), 'v', 'IndexedDB');
    await ctx.close();
  });
  await test('tapping Update now reloads the page and the saved data is still there', async () => {
    const { ctx, page } = await open('/index.html'); await setServer(page, swVersion + 5);
    await page.evaluate(() => { localStorage.setItem('keep_me', 'yes'); return DawamUpdate.check({ popup: true }); });
    const nav = page.waitForEvent('load');
    await page.click('#dawamUpdateNow'); await nav;
    await page.waitForFunction(() => window.DawamUpdate);
    eq(await page.evaluate(() => localStorage.getItem('keep_me')), 'yes');
    await ctx.close();
  });
  await test('Update now while offline refuses with a message and does not clear anything', async () => {
    const { ctx, page } = await open('/index.html', { waitSw: true });
    await page.evaluate(() => { DawamUpdate._state.updatePending = 999; DawamUpdate.showModal('newer'); });
    await ctx.setOffline(true);
    await page.click('#dawamUpdateNow');
    ok((await page.locator('#dawamUpdateText').innerText()).includes('offline'), 'offline message');
    ok((await page.evaluate(async () => (await caches.keys()).length)) > 0, 'caches kept');
    await ctx.close();
  });

  console.log('\nService worker rules');
  await test('network first: a changed file is served fresh (not from the cache); offline falls back to the last copy', async () => {
    const { ctx, page } = await open('/index.html', { waitSw: true });
    const get = () => page.evaluate(async () => { const t = await (await fetch('/__test/counter.js')).text(); return Number(t.match(/\d+/)[0]); });
    const a = await get(), b = await get();
    ok(b > a, `second fetch should be newer than first (got ${a} then ${b})`);
    await goOffline(ctx);
    eq(await get(), b, 'offline: last copy');
    await goOnline(ctx);
    await ctx.close();
  });
  await test('the version check request (?check=) is never answered from the cache', async () => {
    const { ctx, page } = await open('/index.html', { mock: false, waitSw: true });
    ok(await page.evaluate(async () => (await fetch('/sw.js?check=1', { cache: 'no-store' })).ok), 'online works');
    await goOffline(ctx);
    const offlineResult = await page.evaluate(async () => { try { const r = await fetch('/sw.js?check=2', { cache: 'no-store' }); return 'answered ' + r.status; } catch (e) { return 'failed'; } });
    eq(offlineResult, 'failed', 'offline the check must fail, not be served from cache');
    await goOnline(ctx);
    await ctx.close();
  });
  await test('offline: pre-cached pages open (dashboard.html, punch/index.html)', async () => {
    const { ctx, page } = await open('/index.html', { waitSw: true });
    await goOffline(ctx);
    for (const p of ['/punch/index.html', '/admin/settings.html']) {
      const r = await page.goto(url + p).catch(e => null);
      ok(r && r.status() === 200, `${p} should open offline`);
      ok((await page.content()).includes('app-update.js'), `${p} is the real page`);
    }
    await goOnline(ctx);
    await ctx.close();
  });
  await test('old caches from earlier versions are deleted when the new service worker activates', async () => {
    const { ctx, page } = await open('/index.html', { waitSw: true });
    ok(await page.evaluate(async () => { await caches.open('ak-attendance-v68'); return (await caches.keys()).includes('ak-attendance-v68'); }), 'old cache created');
    await page.evaluate(async () => { const r = await navigator.serviceWorker.getRegistration(); await r.unregister(); });
    await page.reload(); await page.waitForFunction(() => navigator.serviceWorker.controller || true);
    await page.evaluate(() => navigator.serviceWorker.ready);
    await page.waitForFunction(async () => !(await caches.keys()).includes('ak-attendance-v68'), null, { timeout: 15000 });
    await ctx.close();
  });

  console.log('\nInstall prompt (punch terminal)');
  await test('browser install prompt: an Install button appears and calls the browser prompt', async () => {
    const { ctx, page } = await open('/punch/index.html');
    await page.evaluate(() => {
      window.__prompted = false;
      const e = new Event('beforeinstallprompt', { cancelable: true });
      e.prompt = () => { window.__prompted = true; return Promise.resolve(); };
      e.userChoice = Promise.resolve({ outcome: 'accepted' });
      window.dispatchEvent(e);
    });
    await page.waitForSelector('#dawamInstallBar.show');
    const box = await page.locator('.dawam-install-box').boundingBox(), vp = page.viewportSize();
    ok(Math.abs(box.y + box.height / 2 - vp.height / 2) < vp.height * 0.15 && Math.abs(box.x + box.width / 2 - vp.width / 2) < vp.width * 0.1, 'install card is in the middle of the screen');
    await page.click('#dawamInstallGo');
    eq(await page.evaluate(() => window.__prompted), true, 'prompt called');
    eq(await page.locator('#dawamInstallBar.show').count(), 0, 'bar hidden after tap');
    await ctx.close();
  });
  await test('"Not now" closes the install card', async () => {
    const { ctx, page } = await open('/punch/index.html');
    await page.evaluate(() => { const e = new Event('beforeinstallprompt', { cancelable: true }); e.prompt = () => Promise.resolve(); window.dispatchEvent(e); });
    await page.waitForSelector('#dawamInstallBar.show'); await page.click('#dawamInstallNo');
    eq(await page.locator('#dawamInstallBar.show').count(), 0);
    await ctx.close();
  });
  await test('update icon uses the new picture and sits right next to "View My Attendance" on the punch terminal', async () => {
    const { ctx, page } = await open('/punch/index.html?client=TEST');
    await page.waitForFunction(() => document.querySelector('.dawam-upd-row .view-attendance-link') && document.querySelector('.dawam-upd-row #dawamUpdateBtn'));
    eq(await page.evaluate(() => document.querySelector('#dawamUpdateBtn img').getAttribute('src')), '/icons/ui-update.png');
    eq(await page.evaluate(() => document.querySelector('#dawamUpdateBtn').previousElementSibling.className), 'view-attendance-link', 'directly after the link');
    eq(await page.evaluate(() => typeof openViewAttendance), 'function', 'link still works');
    await ctx.close();
  });
  await test('iPhone: shows the Add to Home Screen hint once, remembers when dismissed', async () => {
    const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    const { ctx, page } = await open('/punch/index.html', { ctxOpts: { userAgent: ua } });
    await page.waitForSelector('#dawamInstallBar.show');
    ok((await page.locator('#dawamInstallBar').innerText()).includes('Add to Home Screen'));
    await page.click('#dawamInstallNo');
    await page.reload(); await page.waitForTimeout(800);
    eq(await page.locator('#dawamInstallBar.show').count(), 0, 'stays hidden after dismiss');
    await ctx.close();
  });

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
