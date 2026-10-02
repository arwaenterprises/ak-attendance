// Smoke test: log in on staging, open every page, make sure no script error and no missing local file.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '..');
const SHOTS = process.env.SHOT_DIR;       // optional: save screenshots here

const PAGES = ['/index.html', '/dashboard.html', '/admin/departments.html', '/admin/settings.html', '/admin/shifts.html', '/admin/terminal-link.html', '/admin/users.html',
  '/attendance/lop.html', '/attendance/overtime.html', '/attendance/punch-locations.html', '/labor/enroll.html',
  '/labor/import.html', '/labor/master.html', '/reports/3pl-billing.html', '/reports/daily.html'];

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, serviceWorkers: 'block' });   // page logic only; the service worker is covered by update.test.js
  await curlRoutes(ctx, /jsdelivr|supabase\.co/);
  await ctx.route(/justadudewhohacks/, r => r.abort());
  const page = await ctx.newPage();
  await page.goto(url + '/index.html');
  await page.waitForFunction(() => typeof AUTH !== 'undefined');
  const login = await page.evaluate(() => AUTH.login('TEST', 'admin', 'Test@1234'));
  ok(login.success, 'login for smoke test failed: ' + JSON.stringify(login));

  for (const p of PAGES) {
    await test(`${p} opens, no script errors, no missing local files, update icon present`, async () => {
      const errors = [], missing = [], refused = [];
      const onErr = e => errors.push(e.message); const onResp = r => { if (r.url().startsWith(url) && r.status() >= 400) missing.push(r.status() + ' ' + r.url().replace(url, '')); else if (/supabase\.co\/(rest|storage)/.test(r.url()) && r.status() >= 400 && r.status() !== 406) refused.push(r.status() + ' ' + r.request().method() + ' ' + new URL(r.url()).pathname.replace('/rest/v1/', '') ); };
      page.on('pageerror', onErr); page.on('response', onResp);
      await page.goto(url + p); await page.waitForFunction(() => document.getElementById('dawamUpdateBtn'), null, { timeout: 15000 });
      await page.waitForTimeout(1200);
      page.off('pageerror', onErr); page.off('response', onResp);
      eq(errors, [], 'script errors'); eq(missing.filter(m => !m.includes('favicon')), [], 'missing files');
      eq(refused, [], 'database requests refused or failing while logged in (406 = a lookup that found no row, harmless)');
      if (SHOTS && ['/dashboard.html', '/admin/settings.html'].includes(p)) await page.screenshot({ path: path.join(SHOTS, 'header' + p.replace(/[\/.]/g, '_') + '.png') });
    });
  }
  await test('/punch/index.html (no client code) opens with no script errors; update icon present', async () => {
    const errors = []; const onErr = e => errors.push(e.message); page.on('pageerror', onErr);
    await page.goto(url + '/punch/index.html'); await page.waitForFunction(() => document.getElementById('dawamUpdateBtn'), null, { timeout: 15000 });
    await page.waitForTimeout(1200); page.off('pageerror', onErr);
    eq(errors, [], 'script errors');
  });
  await test('/labor/enroll-self.html opens with no script errors', async () => {
    const errors = []; const onErr = e => errors.push(e.message); page.on('pageerror', onErr);
    await page.goto(url + '/labor/enroll-self.html'); await page.waitForTimeout(1500); page.off('pageerror', onErr);
    eq(errors, [], 'script errors');
  });
  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
