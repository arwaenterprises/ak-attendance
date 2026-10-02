// Shift Management page (admin/shifts.html) against the STAGING project (needs migration 010 there).
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const rid = Math.random().toString(36).slice(2, 7).toUpperCase();
const LABOR = 'SHF' + rid;

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, serviceWorkers: 'block' });
  await curlRoutes(ctx, /jsdelivr|supabase\.co/);
  const page = await ctx.newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message)); page.on('dialog', d => d.accept());
  await page.goto(url + '/index.html');
  await page.fill('#clientCode', 'TEST'); await page.fill('#username', 'admin'); await page.fill('#password', 'Test@1234'); await page.click('#loginBtn');
  await page.waitForURL(/dashboard/, { timeout: 30000 });

  // a test labor
  const setup = await page.evaluate(async (L) => {
    const cid = AUTH.getClientId(), r = L.slice(3);
    const d = await supabaseClient.from('departments').insert({ name: 'SHIFT ' + r, code: 'S' + r, client_id: cid }).select().single();
    const iq = '8' + String(Math.floor(Math.random() * 1e9)).padStart(9, '0');
    await supabaseClient.from('iqama_registry').insert({ iqama_number: iq, labor_id: L, client_id: cid });
    const l = await supabaseClient.from('laborers').insert({ labor_id: L, iqama_number: iq, name: 'Shift Tester', nationality: 'X', date_of_joining: '2020-01-01', department_id: d.data.id, client_id: cid }).select().single();
    return { ok: !!(d.data && l.data), err: (d.error || l.error || {}).message };
  }, LABOR);
  ok(setup.ok, 'setup: ' + JSON.stringify(setup));

  await test('the dashboard has a Shifts tile that opens Shift Management', async () => {
    await page.waitForSelector('text=Shifts', { timeout: 15000 });
    await page.click('a[href="admin/shifts.html"], [onclick*="admin/shifts.html"], text=Shifts');
    await page.waitForURL(/admin\/shifts\.html/, { timeout: 15000 });
  });
  await test('the Shifts tab lists the Day and the Night shift with their times', async () => {
    await page.waitForFunction(() => document.querySelectorAll('#shiftTable tr').length === 2, null, { timeout: 20000 });
    const t = await page.locator('#shiftTable').innerText();
    ok(/Day shift/.test(t) && /Night shift/.test(t), t);
  });
  await test('Edit: the Night shift gets its hours and keeps them after reload', async () => {
    await page.click('#shiftTable tr:nth-child(2) button');
    await page.fill('#shiftHours', '10'); await page.click('text=💾 Save');
    await page.waitForFunction(() => /10 h/.test(document.getElementById('shiftTable').innerText), null, { timeout: 15000 });
    await page.reload(); await page.waitForFunction(() => /10 h/.test(document.getElementById('shiftTable').innerText), null, { timeout: 20000 });
  });
  await test('Assign: find the labor, move it to Night from today; the badge, the count and the database follow', async () => {
    await page.click('#tabBtnAssign');
    await page.fill('#fId', LABOR);
    await page.waitForFunction(() => document.querySelectorAll('#laborTable tr').length === 1 && /Day shift/.test(document.getElementById('laborTable').innerText), null, { timeout: 15000 });
    await page.check('#laborTable input[type=checkbox]');
    eq(await page.locator('#selectedCount').innerText(), '1 selected');
    await page.selectOption('#moveShift', { label: 'Night shift' });
    await page.click('#moveBtn');
    await page.waitForFunction(() => /Night shift/.test(document.getElementById('laborTable').innerText), null, { timeout: 20000 });
    const db = await page.evaluate(async (L) => { const r = await supabaseClient.from('laborers').select('shift_id, shifts:shift_id (code)').eq('labor_id', L).single(); return r.data; }, LABOR);
    eq(db.shifts.code, 'NIGHT');
  });
  await test('History: the move is listed', async () => {
    await page.click('#tabBtnHistory');
    await page.waitForFunction((L) => document.getElementById('historyTable').innerText.includes(L), LABOR, { timeout: 15000 });
  });
  await test('the Night shift cannot be switched off while a labor is on it', async () => {
    await page.click('#tabBtnShifts');
    await page.click('#shiftTable tr:nth-child(2) button');
    await page.selectOption('#shiftStatus', 'inactive'); await page.click('text=💾 Save');
    await page.waitForSelector('text=Move the labors of this shift', { timeout: 10000 });
    const st = await page.evaluate(async () => (await supabaseClient.from('shifts').select('status').eq('code', 'NIGHT').eq('client_id', AUTH.getClientId()).single()).data.status);
    eq(st, 'active'); await page.click('.modal-close');
  });
  await test('put the labor back to Day (so the staging data stays tidy)', async () => {
    await page.click('#tabBtnAssign'); await page.fill('#fId', LABOR);
    await page.waitForFunction(() => document.querySelectorAll('#laborTable tr').length === 1);
    await page.check('#laborTable input[type=checkbox]'); await page.selectOption('#moveShift', { label: 'Day shift' }); await page.click('#moveBtn');
    await page.waitForFunction(() => /Day shift/.test(document.getElementById('laborTable').innerText), null, { timeout: 20000 });
    await page.evaluate(async () => { await supabaseClient.from('shifts').update({ required_hours: null }).eq('code', 'NIGHT').eq('client_id', AUTH.getClientId()); });
  });
  await test('no script errors', async () => { eq(errors, []); });

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
