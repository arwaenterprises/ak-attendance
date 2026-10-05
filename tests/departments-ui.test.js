// Departments page against the STAGING project (needs migration 017 there):
// Min Hours is saved, active-labor counts, moving labors, switching a department off (two confirmations, labors go with it),
// and the daily report (labors switched off keep their rows up to the last working day; a moved labor keeps its earlier days).
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const rid = Math.random().toString(36).slice(2, 7).toUpperCase();
const LA = 'DPA' + rid, LB = 'DPB' + rid, LC = 'DPC' + rid;       // A + B start in department ONE, C starts in TWO
const pad = n => String(n).padStart(2, '0');
const ymd = d => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, serviceWorkers: 'block' });
  await curlRoutes(ctx, /jsdelivr|supabase\.co/);
  const page = await ctx.newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  const dialogs = []; let dialogMode = 'accept';
  page.on('dialog', async d => { dialogs.push(d.message()); if (dialogMode === 'dismiss-second' && dialogs.length % 2 === 0) await d.dismiss(); else await d.accept(); });
  await page.goto(url + '/index.html');
  await page.fill('#clientCode', 'TEST'); await page.fill('#username', 'admin'); await page.fill('#password', 'Test@1234'); await page.click('#loginBtn');
  await page.waitForURL(/dashboard/, { timeout: 30000 });

  const today = ymd(new Date()), yesterday = ymd(new Date(Date.now() - 86400000));
  const setup = await page.evaluate(async (a) => {
    const cid = AUTH.getClientId();
    const mkDept = async (code, name, minHours) => (await supabaseClient.from('departments').insert({ name, code, client_id: cid, status: 'active', ...(minHours ? { min_hours_full_day: minHours } : {}) }).select().single());
    const d1 = await mkDept('P1' + a.rid, 'Dept One ' + a.rid), d2 = await mkDept('P2' + a.rid, 'Dept Two ' + a.rid);
    const mk = async (L, dept) => {
      const iq = '8' + String(Math.floor(Math.random() * 1e9)).padStart(9, '0');
      await supabaseClient.from('iqama_registry').insert({ iqama_number: iq, labor_id: L, client_id: cid });
      return supabaseClient.from('laborers').insert({ labor_id: L, iqama_number: iq, name: 'Dept Test ' + L, nationality: 'X', date_of_joining: '2020-01-01', department_id: dept, client_id: cid });
    };
    const errs = [d1.error, d2.error, (await mk(a.LA, d1.data.id)).error, (await mk(a.LB, d1.data.id)).error, (await mk(a.LC, d2.data.id)).error].filter(Boolean).map(e => e.message);
    // yesterday: labor A was present under department ONE
    const att = await supabaseClient.from('daily_attendance').insert({ labor_id: a.LA, department_id: d1.data.id, date: a.yesterday, first_login: '06:00', last_logout: '16:30', total_hours: 10.5, auto_status: 'P', final_status: 'P', client_id: cid });
    if (att.error) errs.push(att.error.message);
    return { errs, d1: d1.data && d1.data.id, d2: d2.data && d2.data.id };
  }, { rid, LA, LB, LC, yesterday });
  ok(setup.errs.length === 0 && setup.d1 && setup.d2, 'setup: ' + JSON.stringify(setup));
  const dbLabor = (L) => page.evaluate(async (L) => (await supabaseClient.from('laborers').select('department_id, status, last_working_date').eq('labor_id', L).single()).data, L);
  const dbDept = (id) => page.evaluate(async (id) => (await supabaseClient.from('departments').select('status, min_hours_full_day').eq('id', id).single()).data, setup.d1 && id);

  await page.goto(url + '/admin/departments.html');
  await page.waitForFunction((c) => document.getElementById('departmentTable').innerText.includes(c), 'P1' + rid, { timeout: 30000 });
  const row = (code) => page.locator('#departmentTable tr', { hasText: code });

  await test('the table shows the number of active labors per department (2 and 1)', async () => {
    ok(/\b2\b/.test(await row('P1' + rid).innerText()), await row('P1' + rid).innerText());
    ok(/\b1\b/.test(await row('P2' + rid).innerText()), await row('P2' + rid).innerText());
  });

  await test('Min Hours is saved (it used to be ignored): edit Dept Two to 08:00', async () => {
    await row('P2' + rid).locator('text=Edit').click();
    await page.fill('#deptMinHours', '08:00'); await page.click('text=💾 Save');
    await page.waitForFunction(() => !document.getElementById('departmentModal').classList.contains('active'), null, { timeout: 15000 });
    const d = await dbDept(setup.d2); ok(/^08:00/.test(d.min_hours_full_day), JSON.stringify(d));
  });

  await test('Move labors: B moves from Dept One to Dept Two; A stays', async () => {
    await row('P1' + rid).locator('text=Move labors').click();
    await page.waitForFunction(() => document.getElementById('moveModal').classList.contains('active') && document.querySelectorAll('.move-cb').length >= 2, null, { timeout: 15000 });
    await page.selectOption('#moveToDept', setup.d2);
    await page.uncheck('.move-cb[value="' + LA + '"]');
    ok(/1 of 2/.test(await page.locator('#moveCount').innerText()), await page.locator('#moveCount').innerText());
    await page.click('#moveBtn');
    await page.waitForFunction(() => !document.getElementById('moveModal').classList.contains('active'), null, { timeout: 15000 });
    eq((await dbLabor(LB)).department_id, setup.d2); eq((await dbLabor(LA)).department_id, setup.d1);
  });

  await test('switching a department off: cancelling the second confirmation changes nothing', async () => {
    dialogs.length = 0; dialogMode = 'dismiss-second';
    await row('P1' + rid).locator('text=Edit').click();
    await page.selectOption('#deptStatus', 'inactive');
    ok(/1 active labor/.test(await page.locator('#deptStatusHint').innerText()), await page.locator('#deptStatusHint').innerText());
    await page.click('text=💾 Save');
    await page.waitForFunction(() => true); await page.waitForTimeout(800);
    eq(dialogs.length, 2); eq((await dbDept(setup.d1)).status, 'active'); eq((await dbLabor(LA)).status, 'active');
    await page.click('#departmentModal .modal-close');
  });

  await test('switching a department off: two confirmations, then the department and its labor are off, last working day = today', async () => {
    dialogs.length = 0; dialogMode = 'accept';
    await row('P1' + rid).locator('text=Edit').click();
    await page.selectOption('#deptStatus', 'inactive'); await page.click('text=💾 Save');
    await page.waitForFunction(() => !document.getElementById('departmentModal').classList.contains('active'), null, { timeout: 15000 });
    eq(dialogs.length, 2); ok(/1 active labor/.test(dialogs[0]) && /FINAL/.test(dialogs[1]), JSON.stringify(dialogs));
    eq((await dbDept(setup.d1)).status, 'inactive');
    const a = await dbLabor(LA); eq(a.status, 'inactive'); eq(a.last_working_date, today);
    eq((await dbLabor(LC)).status, 'active');                                   // other department untouched
    eq((await dbLabor(LB)).status, 'active');                                   // B was moved to Dept Two before
  });

  await test('an inactive department cannot be a move target, and its labors cannot be switched on again inside it', async () => {
    await page.waitForFunction((c) => /inactive/.test(document.querySelector('#departmentTable tr:has-text("' + c + '")')?.innerText || ''), 'P1' + rid, { timeout: 10000 }).catch(() => {});
    await row('P2' + rid).locator('text=Move labors').click();
    await page.waitForFunction(() => document.getElementById('moveModal').classList.contains('active'), null, { timeout: 15000 }).catch(() => {});
    const opts = await page.evaluate(() => [...document.querySelectorAll('#moveToDept option')].map(o => o.value));
    ok(!opts.includes(setup.d1), JSON.stringify(opts));
    await page.click('#moveModal .modal-close').catch(() => {});
    const r = await page.evaluate(async (L) => (await supabaseClient.from('laborers').update({ status: 'active' }).eq('labor_id', L)).error?.message, LA);
    ok(/department is inactive/i.test(r || ''), String(r));
  });

  await test('daily report: a labor switched off today still shows today; the labor moved to Dept Two still shows its earlier day (present)', async () => {
    await page.evaluate(() => new Promise((res, rej) => { const s = document.createElement('script'); s.src = '../js/api/report-api.js'; s.onload = res; s.onerror = rej; document.head.appendChild(s); }));
    const out = await page.evaluate(async (a) => {
      const t = await ReportAPI.getCompleteAttendance(a.today, a.today, a.d1);
      const y = await ReportAPI.getCompleteAttendance(a.yesterday, a.yesterday, a.d1);
      const toTwo = await ReportAPI.getCompleteAttendance(a.yesterday, a.yesterday, a.d2);
      return { todayHasA: (t.data || []).some(r => r.labor_id === a.LA), yesterdayHasA: (y.data || []).some(r => r.labor_id === a.LA && r.final_status === 'P'), twoHasB: (toTwo.data || []).some(r => r.labor_id === a.LB), err: t.error || y.error || toTwo.error };
    }, { today, yesterday, d1: setup.d1, d2: setup.d2, LA, LB });
    ok(!out.err, JSON.stringify(out));
    ok(out.todayHasA, 'switched-off labor must show on its last working day: ' + JSON.stringify(out));
    ok(out.yesterdayHasA, 'earlier present day must stay: ' + JSON.stringify(out));
    ok(out.twoHasB, 'moved labor must be in the new department report: ' + JSON.stringify(out));
  });

  await test('daily report: the day AFTER the last working day does not list the switched-off labor', async () => {
    const tomorrow = ymd(new Date(Date.now() + 86400000));
    const has = await page.evaluate(async (a) => { const r = await ReportAPI.getCompleteAttendance(a.tomorrow, a.tomorrow, a.d1); return (r.data || []).some(x => x.labor_id === a.LA); }, { tomorrow, d1: setup.d1, LA });
    ok(!has, 'listed after the last working day');
  });

  await test('no script errors', async () => { eq(errors, []); });
  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
