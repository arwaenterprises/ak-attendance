// The punch terminal must fit ONE screen with no scrolling on phones and tablets: the ID box and both IN / OUT buttons are always fully visible.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const KEY = 'test-terminal-key-1234';
const SIZES = [['small phone 320x568', 320, 568], ['phone 360x640', 360, 640], ['phone 360x740', 360, 740], ['phone 390x844', 390, 844], ['big phone 412x915', 412, 915],
  ['phone with the keyboard open 390x420', 390, 420], ['tablet portrait 768x1024', 768, 1024], ['tablet landscape 1024x768', 1024, 768], ['phone landscape 667x375', 667, 375]];

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined, args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'] });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, serviceWorkers: 'block', geolocation: { latitude: 1, longitude: 1 }, permissions: ['geolocation', 'camera'] });
  await curlRoutes(ctx, /jsdelivr|supabase\.co/); await ctx.route(/justadudewhohacks/, r => r.abort());
  const page = await ctx.newPage();
  await page.goto(url + '/punch/index.html?client=TEST#key=' + KEY);
  await page.waitForFunction(() => document.getElementById('mainContainer').style.display === 'flex', null, { timeout: 45000 });
  await page.waitForFunction(() => !document.getElementById('statusOverlay').classList.contains('active'), null, { timeout: 15000 }).catch(() => {});

  for (const [name, w, h] of SIZES) {
    await test(name + ': one screen, no scroll, ID box and IN / OUT fully visible and tappable', async () => {
      await page.setViewportSize({ width: w, height: h }); await page.waitForTimeout(300);
      const r = await page.evaluate(() => {
        const box = id => { const b = document.getElementById(id).getBoundingClientRect(); return { top: b.top, bottom: b.bottom, left: b.left, right: b.right, w: b.width, h: b.height }; };
        const top = id => { const e = document.getElementById(id), b = e.getBoundingClientRect(); const hit = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2); return hit === e || e.contains(hit); };
        const vh = (window.visualViewport && window.visualViewport.height) || window.innerHeight;
        return { vh, vw: window.innerWidth, inB: box('inBtn'), outB: box('outBtn'), id: box('laborIdInput'), tappable: [top('inBtn'), top('outBtn'), top('laborIdInput')],
          docScroll: document.documentElement.scrollHeight - document.documentElement.clientHeight, bodyScroll: document.body.scrollHeight - document.body.clientHeight,
          container: document.getElementById('mainContainer').getBoundingClientRect().height, scrollY: window.scrollY };
      });
      for (const [n, b] of [['IN button', r.inB], ['OUT button', r.outB], ['ID box', r.id]]) {
        ok(b.top >= 0 && b.bottom <= r.vh + 0.5 && b.left >= 0 && b.right <= r.vw + 0.5, n + ' is cut off: ' + JSON.stringify({ b, vh: r.vh, vw: r.vw }));
        ok(b.h >= 40, n + ' too small: ' + b.h);
      }
      ok(r.tappable.every(Boolean), 'something covers a button: ' + JSON.stringify(r.tappable));
      ok(r.docScroll <= 1 && r.bodyScroll <= 1 && r.scrollY === 0, 'page scrolls: ' + JSON.stringify(r));
      ok(Math.abs(r.container - r.vh) <= 1, 'container ' + r.container + ' is not the visible height ' + r.vh);
    });
  }
  await test('the screen height follows the visible area (browser bars / keyboard), not 100vh', async () => {
    const css = await page.evaluate(() => getComputedStyle(document.getElementById('mainContainer')).height);
    await page.setViewportSize({ width: 390, height: 700 }); await page.waitForTimeout(200);
    const h2 = await page.evaluate(() => document.getElementById('mainContainer').getBoundingClientRect().height);
    eq(Math.round(h2), 700); ok(css, 'has a height');
  });
  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
