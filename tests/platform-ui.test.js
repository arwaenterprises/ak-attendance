// Platform owner: the Clients page (create a company, switch on / off, reset the administrator password) against the STAGING project.
// Needs migration 013 on staging AND the owner login created there once:   select public.create_platform_owner('owner', 'Owner@Test1234');
// The test company PTEST is created once and reused (staging does not fill up with test companies); the test always puts it back to a clean state.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const OWNER = ['PLATFORM', 'owner', 'Owner@Test1234'];
const CODE = 'PTEST', USER = 'ptestadmin', PASS = 'PtestAdmin-12345', PASS2 = 'PtestAdmin-67890';

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined, args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'] });
  const newCtx = async () => { const c = await browser.newContext({ viewport: { width: 1200, height: 900 }, serviceWorkers: 'block', permissions: ['geolocation', 'camera'], geolocation: { latitude: 1, longitude: 1 } });
    await curlRoutes(c, /jsdelivr|supabase\.co/); await c.route(/justadudewhohacks/, r => r.abort()); return c; };
  const tryLogin = async (code, user, pass) => {
    const c = await newCtx(); const p = await c.newPage(); await p.goto(url + '/tests/harness.html'); await p.waitForFunction(() => typeof AUTH !== 'undefined');
    const r = await p.evaluate(([a, b, d]) => AUTH.login(a, b, d), [code, user, pass]); await c.close(); return r;
  };

  const ctx = await newCtx(); const page = await ctx.newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message)); page.on('dialog', d => d.accept());
  await page.goto(url + '/index.html');
  await page.fill('#clientCode', OWNER[0]); await page.fill('#username', OWNER[1]); await page.fill('#password', OWNER[2]); await page.click('#loginBtn');
  const loggedIn = await page.waitForURL(/dashboard/, { timeout: 30000 }).then(() => true).catch(() => false);
  if (!loggedIn) { console.error('Owner login failed - was create_platform_owner run on staging? ' + (await page.locator('#loginError, .error, .alert').allInnerTexts().catch(() => [])).join(' ')); process.exit(2); }

  const owner = (name, args) => page.evaluate(async ([n, a]) => { const r = await supabaseClient.rpc(n, a); return r.error ? { error: r.error.message } : { data: r.data }; }, [name, args]);

  await test('the owner dashboard shows only the Clients tile (no company tiles)', async () => {
    await page.waitForSelector('.dashboard-tile', { timeout: 15000 });
    const tiles = await page.locator('.dashboard-tile h3').allInnerTexts();
    eq(tiles, ['Clients']);
    ok(/PLATFORM OWNER/i.test(await page.locator('#userInfo').innerText()));
  });
  await page.getByText('Clients', { exact: true }).first().click();
  await page.waitForURL(/platform-clients/, { timeout: 15000 });

  await test('the Clients page lists the companies with status and counts, platform last', async () => {
    await page.waitForFunction(() => document.querySelectorAll('#clientTable tr').length >= 2 && !/Loading/.test(document.getElementById('clientTable').innerText), null, { timeout: 20000 });
    const t = await page.locator('#clientTable').innerText();
    ok(/TEST/.test(t) && /PLATFORM/.test(t), t.slice(0, 200));
  });

  const exists = (await owner('platform_list_clients', {})).data.some(c => c.client_code === CODE);
  await test(exists ? 'the test company already exists on staging (created by an earlier run)' : 'New client: the form creates the company and shows the details to hand over', async () => {
    if (exists) return;
    await page.click('text=➕ New client');
    await page.fill('#cName', 'Platform Test Co'); await page.fill('#cCode', CODE); await page.fill('#cUser', USER); await page.fill('#cPass', PASS);
    await page.click('#createBtn');
    await page.waitForFunction(() => document.getElementById('madeBox').style.display === 'block', null, { timeout: 20000 });
    const t = await page.locator('#madeText').innerText();
    ok(t.includes('Company code: ' + CODE) && t.includes('Username: ' + USER) && t.includes('Password: ' + PASS), t);
    await page.click('#addModal .modal-footer .btn-secondary');
  });

  // the new company's administrator is real: signs in, gets the terminal link, the link opens the terminal
  await test('the new company administrator can sign in with the details', async () => { const r = await tryLogin(CODE, USER, PASS); ok(r.success, JSON.stringify(r)); });
  await test('and gets the punch link from the Terminal Link page; the link opens the terminal on a fresh browser', async () => {
    const c = await newCtx(); const p = await c.newPage();
    await p.goto(url + '/index.html'); await p.fill('#clientCode', CODE); await p.fill('#username', USER); await p.fill('#password', PASS); await p.click('#loginBtn');
    await p.waitForURL(/dashboard/, { timeout: 30000 });
    await p.goto(url + '/admin/terminal-link.html');
    await p.waitForFunction(() => document.getElementById('ready').style.display === 'block', null, { timeout: 20000 });
    const link = (await p.inputValue('#linkBox')).replace(/^https?:\/\/[^/]+/, url);
    ok(/client=PTEST#key=[A-Za-z0-9]{28}$/.test(link), link);
    const t = await newCtx(); const tp = await t.newPage(); await tp.goto(link);
    await tp.waitForFunction(() => document.getElementById('mainContainer').style.display === 'flex', null, { timeout: 45000 });
    await t.close(); await c.close();
  });

  const pid = (await owner('platform_list_clients', {})).data.find(c => c.client_code === CODE).id;
  try {
    await test('Manage: switching the company OFF locks the administrator out; switching it on lets him in again', async () => {
      await page.reload(); await page.waitForFunction(() => /PTEST/.test(document.getElementById('clientTable').innerText), null, { timeout: 20000 });
      await page.click(`#clientTable tr:has-text("${CODE}") button`);
      await page.selectOption('#mActive', 'false'); await page.click('text=💾 Save');
      await page.waitForFunction((c) => /Off/.test([...document.querySelectorAll('#clientTable tr')].find(r => r.innerText.includes(c)).innerText), CODE, { timeout: 15000 });
      const off = await tryLogin(CODE, USER, PASS); ok(!off.success, 'login still works while switched off: ' + JSON.stringify(off));
      await page.click(`#clientTable tr:has-text("${CODE}") button`);
      await page.selectOption('#mActive', 'true'); await page.selectOption('#mStatus', 'active'); await page.fill('#mEnd', '2099-12-31'); await page.click('text=💾 Save');
      await page.waitForFunction((c) => /Active/.test([...document.querySelectorAll('#clientTable tr')].find(r => r.innerText.includes(c)).innerText), CODE, { timeout: 15000 });
      const on = await tryLogin(CODE, USER, PASS); ok(on.success, JSON.stringify(on));
    });
    await test('Manage: an expired subscription locks the administrator out too', async () => {
      const r = await owner('platform_set_client', { p_client: pid, p_status: 'expired' }); ok(!r.error, JSON.stringify(r));
      const x = await tryLogin(CODE, USER, PASS); ok(!x.success, JSON.stringify(x));
    });
    await test('Manage: a new administrator password works and the old one does not', async () => {
      await owner('platform_set_client', { p_client: pid, p_status: 'active' });
      await page.click(`#clientTable tr:has-text("${CODE}") button`);
      await page.fill('#mPass', PASS2); await page.click('text=Set password');
      await page.waitForSelector('text=Password set', { timeout: 10000 });
      ok((await tryLogin(CODE, USER, PASS2)).success, 'new password');
      ok(!(await tryLogin(CODE, USER, PASS)).success, 'old password must be refused');
    });
    await test('a short password is refused by the page', async () => {
      await page.fill('#mPass', 'short'); await page.click('text=Set password');
      await page.waitForSelector('text=at least 10 characters', { timeout: 10000 });
    });
  } finally {
    // clean state again: switched on, active, no end date, the fixed password
    await owner('platform_set_client', { p_client: pid, p_is_active: true, p_status: 'premium' });
    const r = await owner('platform_reset_admin_password', { p_client: pid, p_password: PASS });
    console.log(r.error ? 'WARNING: could not restore the test company: ' + r.error : 'test company restored');
  }
  await test('a company administrator cannot use the owner functions (even directly)', async () => {
    const c = await newCtx(); const p = await c.newPage(); await p.goto(url + '/tests/harness.html'); await p.waitForFunction(() => typeof AUTH !== 'undefined');
    await p.evaluate(([a, b, d]) => AUTH.login(a, b, d), ['TEST', 'admin', 'Test@1234']);
    const r = await p.evaluate(async () => (await supabaseClient.rpc('platform_list_clients')).error);
    ok(r && /not allowed/i.test(r.message), JSON.stringify(r)); await c.close();
  });
  await test('no script errors', async () => { eq(errors, []); });

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
