// The administrator's login and the punch terminal's login live on the same website. Opening the terminal must never replace the administrator's session
// (that made every admin list empty), and an old saved terminal session must never be used as an administrator.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const KEY = 'test-terminal-key-1234';

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined, args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'] });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block', geolocation: { latitude: 1, longitude: 1 }, permissions: ['geolocation', 'camera'] });
  await curlRoutes(ctx, /jsdelivr|supabase\.co/); await ctx.route(/justadudewhohacks/, r => r.abort());
  const page = await ctx.newPage();
  const laborRows = async () => { await page.goto(url + '/labor/master.html'); await page.waitForTimeout(4000); return page.locator('#laborTable tr').count(); };
  const hasRealRows = async () => (await page.locator('#laborTable').innerText()).trim().length > 0 && !/No laborers found/i.test(await page.locator('#laborTable').innerText());

  await page.goto(url + '/index.html');
  await page.fill('#clientCode', 'TEST'); await page.fill('#username', 'admin'); await page.fill('#password', 'Test@1234'); await page.click('#loginBtn');
  await page.waitForURL(/dashboard/, { timeout: 30000 });

  await test('the administrator sees laborers after login', async () => { await laborRows(); ok(await hasRealRows(), 'no laborers shown'); });

  await test('opening the punch terminal in the SAME browser does not replace the administrator session', async () => {
    const term = await ctx.newPage();
    await term.goto(url + '/punch/index.html?client=TEST#key=' + KEY);
    await term.waitForFunction(() => document.getElementById('mainContainer').style.display === 'flex', null, { timeout: 45000 });
    const keys = await term.evaluate(() => Object.keys(localStorage).filter(k => /auth-token|dawam-terminal-auth/.test(k)));
    ok(keys.some(k => k.includes('dawam-terminal-auth')), 'terminal keeps its own saved session: ' + JSON.stringify(keys));
    await laborRows(); ok(await hasRealRows(), 'administrator lists went empty after the terminal started');
    await term.close();
  });

  await test('an old saved TERMINAL session on an administrator page is not accepted: back to the login page', async () => {
    await page.goto(url + '/dashboard.html'); await page.waitForTimeout(1500);
    await page.evaluate(async (k) => { await supabaseClient.auth.signInWithPassword({ email: 'terminal@test.dawam.arwaenterprises.com', password: k }); }, KEY);
    await page.goto(url + '/dashboard.html').catch(() => {});   // the page may redirect while it is still loading
    await page.waitForFunction(() => /index\.html$/.test(location.pathname), null, { timeout: 20000 });
    ok(/index\.html/.test(page.url()), page.url());
  });

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
