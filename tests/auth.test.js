// End-to-end tests of the NEW login against the STAGING Supabase project (ROADMAP security step S2).
// Needs the staging setup: supabase/staging-security-bundle.sql applied + Auth user admin@test.dawam.arwaenterprises.com.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const GENERAL_ERROR = 'Invalid company code, username or password';

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined });
  const open = async (pagePath) => {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, serviceWorkers: 'block' });
    await curlRoutes(ctx, /jsdelivr|supabase\.co/);
    await ctx.route(/justadudewhohacks/, r => r.abort());
    const page = await ctx.newPage();
    await page.goto(url + pagePath);
    return { ctx, page };
  };
  const uiLogin = async (page, code, user, pass) => {
    await page.fill('#clientCode', code); await page.fill('#username', user); await page.fill('#password', pass); await page.click('#loginBtn');
  };

  // safety: staging only
  { const { ctx, page } = await open('/tests/harness.html');
    await page.waitForFunction(() => typeof SUPABASE_URL !== 'undefined');
    const t = await page.evaluate(() => SUPABASE_URL);
    if (!t.includes('jbfdaeyqsszoacrijldk')) { console.error('REFUSING to run: not staging: ' + t); process.exit(2); }
    await ctx.close(); }

  console.log('Login screen');
  await test('correct company code, username and password open the dashboard of that company', async () => {
    const { ctx, page } = await open('/index.html');
    await uiLogin(page, 'TEST', 'admin', 'Test@1234');
    await page.waitForURL('**/dashboard.html', { timeout: 30000 });
    await page.waitForFunction(() => (document.getElementById('company-name') || {}).textContent === 'Test Company', null, { timeout: 15000 });
    await ctx.close();
  });
  await test('company code is not case sensitive and the username is trimmed', async () => {
    const { ctx, page } = await open('/index.html');
    await uiLogin(page, 'test', ' Admin ', 'Test@1234');
    await page.waitForURL('**/dashboard.html', { timeout: 30000 });
    await ctx.close();
  });
  await test('wrong password: one general message, stays on the login page', async () => {
    const { ctx, page } = await open('/index.html');
    await uiLogin(page, 'TEST', 'admin', 'not-the-password');
    await page.waitForFunction(() => document.getElementById('errorMsg').classList.contains('active'), null, { timeout: 20000 });
    ok((await page.locator('#errorMsg').innerText()).includes(GENERAL_ERROR), await page.locator('#errorMsg').innerText());
    ok(page.url().endsWith('/index.html'), 'still on login page');
    await ctx.close();
  });
  await test('wrong company code: the same general message', async () => {
    const { ctx, page } = await open('/index.html');
    await uiLogin(page, 'NOSUCH', 'admin', 'Test@1234');
    await page.waitForFunction(() => document.getElementById('errorMsg').classList.contains('active'), null, { timeout: 20000 });
    ok((await page.locator('#errorMsg').innerText()).includes(GENERAL_ERROR));
    await ctx.close();
  });
  await test('odd characters in the company code or username are refused without any request', async () => {
    const { ctx, page } = await open('/index.html');
    let calls = 0; page.on('request', r => { if (r.url().includes('/auth/v1/token')) calls++; });
    await uiLogin(page, 'TE ST', "ad'min", 'x');
    await page.waitForFunction(() => document.getElementById('errorMsg').classList.contains('active'), null, { timeout: 10000 });
    eq(calls, 0, 'sign-in requests sent');
    await ctx.close();
  });

  console.log('\nSessions');
  await test('the login survives a page reload', async () => {
    const { ctx, page } = await open('/index.html');
    await uiLogin(page, 'TEST', 'admin', 'Test@1234'); await page.waitForURL('**/dashboard.html', { timeout: 30000 });
    await page.reload(); await page.waitForTimeout(2500);
    ok(page.url().endsWith('/dashboard.html'), 'still on dashboard: ' + page.url());
    ok(await page.evaluate(async () => !!(await supabaseClient.auth.getSession()).data.session), 'Auth session present');
    await ctx.close();
  });
  await test('two devices, same admin: logging out on one does NOT log out the other', async () => {
    const A = await open('/index.html'), B = await open('/index.html');
    for (const d of [A, B]) { await uiLogin(d.page, 'TEST', 'admin', 'Test@1234'); await d.page.waitForURL('**/dashboard.html', { timeout: 30000 }); }
    await A.page.click('text=Logout'); await A.page.waitForURL('**/index.html', { timeout: 20000 });
    await B.page.reload(); await B.page.waitForTimeout(2500);
    ok(B.page.url().endsWith('/dashboard.html'), 'device B must stay logged in, got ' + B.page.url());
    await A.ctx.close(); await B.ctx.close();
  });
  await test('a leftover screen session without a real login is sent back to the login page', async () => {
    const { ctx, page } = await open('/index.html');
    await page.evaluate(() => localStorage.setItem('ak_attendance_session', JSON.stringify({ userId: 'x', username: 'admin', name: 'Fake', role: 'admin', clientId: '00000000-0000-0000-0000-000000000001', clientCode: 'TEST', permissions: {} })));
    await page.goto(url + '/dashboard.html'); await page.waitForURL('**/index.html', { timeout: 20000 });
    eq(await page.evaluate(() => localStorage.getItem('ak_attendance_session')), null, 'fake session removed');
    await ctx.close();
  });
  await test('Users page is gone: no Users tile and the page no longer exists', async () => {
    const { ctx, page } = await open('/index.html');
    await uiLogin(page, 'TEST', 'admin', 'Test@1234'); await page.waitForURL('**/dashboard.html', { timeout: 30000 });
    await page.waitForTimeout(1000);
    eq(await page.locator('text=Manage users').count(), 0, 'Users tile');
    const gone = await page.goto(url + '/admin/users.html'); ok(gone && gone.status() === 404, 'the old Users page must be gone, got ' + (gone && gone.status()));
    await ctx.close();
  });

  console.log('\nThe public key is locked out (real staging database)');
  const anon = async (fn) => { const { ctx, page } = await open('/tests/harness.html'); await page.waitForFunction(() => typeof SUPABASE_URL !== 'undefined');
    const r = await page.evaluate(fn); await ctx.close(); return r; };
  await test('without a login, no table can be read or changed', async () => {
    const r = await anon(async () => {
      const c = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
      const out = {};
      for (const t of ['users', 'clients', 'laborers', 'settings', 'punch_records', 'departments', 'daily_attendance', 'audit_log', 'enrollment_links']) {
        const res = await c.from(t).select('*').limit(1);
        out[t] = { rows: (res.data || []).length, error: !!res.error };
      }
      const ins = await c.from('departments').insert({ name: 'X', code: 'XX' + Date.now() });
      out.insertRefused = !!ins.error;
      const del = await c.from('settings').delete().eq('key', 'night_shift_start');
      out.deleteRefused = !!del.error;
      return out;
    });
    for (const t of ['users', 'clients', 'laborers', 'settings', 'punch_records', 'departments', 'daily_attendance', 'audit_log', 'enrollment_links']) { eq(r[t].rows, 0, t + ' rows readable'); ok(r[t].error, t + ' should be refused, not just empty'); }
    ok(r.insertRefused && r.deleteRefused, 'insert/delete must be refused');
  });
  await test('without a login, the database functions cannot be used', async () => {
    const r = await anon(async () => {
      const c = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
      const a = await c.rpc('register_iqama', { p_iqama: '1234567890' });
      const b = await c.rpc('update_daily_attendance', { p_labor_id: 'L1', p_date: '2020-01-01' });
      return { a: !!a.error, b: !!b.error };
    });
    ok(r.a && r.b, 'both functions must be refused: ' + JSON.stringify(r));
  });
  await test('even when logged in, password hashes cannot be read and the company row cannot be edited', async () => {
    const { ctx, page } = await open('/tests/harness.html'); await page.waitForFunction(() => typeof AUTH !== 'undefined');
    const r = await page.evaluate(async () => {
      const l = await AUTH.login('TEST', 'admin', 'Test@1234');
      const hash = await supabaseClient.from('users').select('password_hash');
      const upd = await supabaseClient.from('clients').update({ subscription_status: 'premium' }).eq('client_code', 'TEST').select();
      const own = await supabaseClient.from('users').select('username');
      return { login: l.success, hashRefused: !!hash.error, updateChanged: (upd.data || []).length, ownRows: (own.data || []).length };
    });
    ok(r.login, 'login'); ok(r.hashRefused, 'password_hash must be refused'); eq(r.updateChanged, 0, 'rows changed in clients'); eq(r.ownRows, 1, 'only my own user row is visible');
    await ctx.close();
  });

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
