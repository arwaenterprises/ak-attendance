// "Punch Terminal Link" page: the administrator gets the link and QR code inside the app; the link really opens the terminal; a new link replaces the old one.
// Runs against the STAGING project (needs migration 012 there). It always puts the fixed staging terminal key back at the end (other tests use it).
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const FIXED = 'test-terminal-key-1234';

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined, args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'] });
  const newCtx = async () => { const c = await browser.newContext({ viewport: { width: 1100, height: 900 }, serviceWorkers: 'block', permissions: ['geolocation', 'camera'], geolocation: { latitude: 1, longitude: 1 } });
    await curlRoutes(c, /jsdelivr|supabase\.co/); await c.route(/justadudewhohacks/, r => r.abort()); return c; };
  const adminCtx = await newCtx(); const page = await adminCtx.newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message)); page.on('dialog', d => d.accept());
  await page.goto(url + '/index.html');
  await page.fill('#clientCode', 'TEST'); await page.fill('#username', 'admin'); await page.fill('#password', 'Test@1234'); await page.click('#loginBtn');
  await page.waitForURL(/dashboard/, { timeout: 30000 });

  // opens a link in a brand-new browser (nothing saved) and tells whether the terminal started or refused the key
  const tryLink = async (link) => {
    const c = await newCtx(); const p = await c.newPage();
    await p.goto(link.replace(/^https?:\/\/[^/]+/, url));
    const res = await Promise.race([
      p.waitForFunction(() => document.getElementById('mainContainer').style.display === 'flex', null, { timeout: 45000 }).then(() => 'started'),
      p.waitForFunction(() => document.getElementById('invalidClientScreen').classList.contains('active'), null, { timeout: 45000 }).then(() => 'refused')]);
    await c.close(); return res;
  };

  try {
    await test('the administrator can choose a key (staging starts from the fixed test key)', async () => {
      const r = await page.evaluate(async (k) => (await supabaseClient.rpc('get_terminal_key', { p_new: false, p_set: k })), FIXED);
      ok(!r.error && r.data.key === FIXED, JSON.stringify(r));
    });
    await test('the dashboard has a Terminal Link tile that opens the page', async () => {
      await page.getByText('Terminal Link', { exact: true }).first().click();
      await page.waitForURL(/admin\/terminal-link\.html/, { timeout: 15000 });
    });
    let link1;
    await test('the page shows the full link (company code and key) and a QR code', async () => {
      await page.waitForFunction(() => document.getElementById('ready').style.display === 'block', null, { timeout: 20000 });
      link1 = await page.inputValue('#linkBox');
      ok(/\/punch\/index\.html\?client=TEST#key=test-terminal-key-1234$/.test(link1), link1);
      ok(await page.locator('#qrBox svg rect').count() > 100, 'QR code drawn');
    });
    await test('the link opens the punch terminal on a phone that has nothing saved (the key really works)', async () => { eq(await tryLink(link1), 'started'); });
    await test('reloading the page shows the SAME link (nothing changes by looking)', async () => {
      await page.reload(); await page.waitForFunction(() => document.getElementById('ready').style.display === 'block', null, { timeout: 20000 });
      eq(await page.inputValue('#linkBox'), link1);
    });
    let link2;
    await test('"Create a new link" gives a different link that works, and the old link stops working', async () => {
      await page.click('#newBtn');
      await page.waitForFunction((old) => document.getElementById('linkBox').value !== old, link1, { timeout: 20000 });
      link2 = await page.inputValue('#linkBox');
      ok(/#key=[A-Za-z0-9]{28}$/.test(link2), link2);
      eq(await tryLink(link2), 'started');
      eq(await tryLink(link1), 'refused');
    });
    await test('no script errors', async () => { eq(errors, []); });
  } finally {
    // always put the fixed key back: the other staging tests sign in with it
    const r = await page.evaluate(async (k) => (await supabaseClient.rpc('get_terminal_key', { p_new: false, p_set: k })), FIXED);
    console.log(r.error ? 'WARNING: could not restore the fixed staging key: ' + r.error.message : 'fixed staging key restored');
  }
  await test('the fixed staging key works again', async () => { eq(await tryLink(url + '/punch/index.html?client=TEST#key=' + FIXED), 'started'); });

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
