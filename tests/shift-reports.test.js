// Labor Master and the daily report follow the shifts: Shift column + filter, "Early" mark on an early leave. Against the STAGING project (needs 010 + 011 there).
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const rid = Math.random().toString(36).slice(2, 7).toUpperCase();
const LN = 'SRN' + rid, LD = 'SRD' + rid;     // a night labor and a day labor
const pad = n => String(n).padStart(2, '0');
const ymd = d => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined });
  const ctx = await browser.newContext({ viewport: { width: 1500, height: 900 }, serviceWorkers: 'block' });
  await curlRoutes(ctx, /jsdelivr|supabase\.co/);
  const page = await ctx.newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message)); page.on('dialog', d => d.accept());
  await page.goto(url + '/index.html');
  await page.fill('#clientCode', 'TEST'); await page.fill('#username', 'admin'); await page.fill('#password', 'Test@1234'); await page.click('#loginBtn');
  await page.waitForURL(/dashboard/, { timeout: 30000 });

  const day = ymd(new Date(Date.now() - 86400000));       // yesterday
  const setup = await page.evaluate(async ([a]) => {
    const cid = AUTH.getClientId();
    const shifts = (await supabaseClient.from('shifts').select('id, code').eq('client_id', cid)).data;
    const night = shifts.find(s => s.code === 'NIGHT').id;
    const d = await supabaseClient.from('departments').insert({ name: 'SR ' + a.LN.slice(3), code: 'R' + a.LN.slice(3), client_id: cid }).select().single();
    const mk = async (L, iq) => {
      await supabaseClient.from('iqama_registry').insert({ iqama_number: iq, labor_id: L, client_id: cid });
      return supabaseClient.from('laborers').insert({ labor_id: L, iqama_number: iq, name: 'Shift Report ' + L, nationality: 'X', date_of_joining: '2020-01-01', department_id: d.data.id, client_id: cid });
    };
    const e1 = (await mk(a.LN, '8' + String(Math.floor(Math.random() * 1e9)).padStart(9, '0'))).error, e2 = (await mk(a.LD, '8' + String(Math.floor(Math.random() * 1e9)).padStart(9, '0'))).error;
    // the night labor is moved to Night from two days ago; both have a punched day yesterday, the night labor left early
    const mv = await supabaseClient.rpc('assign_shift', { p_labor_ids: [a.LN], p_shift_id: night, p_from: a.twoDaysAgo });
    const rows = [
      { labor_id: a.LN, department_id: d.data.id, date: a.day, time: '06:00:00', type: 'login', client_id: cid, early_out: false },
      { labor_id: a.LN, department_id: d.data.id, date: a.day, time: '11:00:00', type: 'logout', client_id: cid, early_out: true, early_minutes: 270 },
      { labor_id: a.LD, department_id: d.data.id, date: a.day, time: '06:00:00', type: 'login', client_id: cid, early_out: false },
      { labor_id: a.LD, department_id: d.data.id, date: a.day, time: '16:30:00', type: 'logout', client_id: cid, early_out: false }];
    const p = await supabaseClient.from('punch_records').insert(rows);
    return { err: [e1, e2, mv.error, p.error].filter(Boolean).map(e => e.message), dept: d.data.id };
  }, [{ LN, LD, day, twoDaysAgo: ymd(new Date(Date.now() - 2 * 86400000)) }]);
  ok(setup.err.length === 0, 'setup: ' + JSON.stringify(setup));

  await test('Labor Master: a Shift column shows Day or Night for each labor and the filter works', async () => {
    await page.goto(url + '/labor/master.html');
    await page.waitForFunction((L) => document.getElementById('laborTable').innerText.includes(L), LN, { timeout: 30000 });
    const rowN = page.locator('#laborTable tr', { hasText: LN }), rowD = page.locator('#laborTable tr', { hasText: LD });
    ok(/Night shift/.test(await rowN.innerText()), await rowN.innerText());
    ok(/Day shift/.test(await rowD.innerText()), await rowD.innerText());
    await page.selectOption('#shiftFilter', { label: 'Night shift' });
    await page.waitForFunction((L) => !document.getElementById('laborTable').innerText.includes(L), LD, { timeout: 10000 });
    ok((await page.locator('#laborTable').innerText()).includes(LN));
  });

  await test('Daily report: Shift column per row, and an early leave is marked with the missing time', async () => {
    await page.goto(url + '/reports/daily.html');
    await page.waitForFunction(() => document.getElementById('fromDate'), null, { timeout: 20000 });
    await page.evaluate((d) => { document.getElementById('fromDate').value = d; document.getElementById('toDate').value = d; }, day);
    await page.click('text=📊 Generate');
    await page.waitForFunction((L) => document.getElementById('reportTable').innerText.includes(L), LN, { timeout: 40000 });
    const rowN = page.locator('#reportTable tr', { hasText: LN }), rowD = page.locator('#reportTable tr', { hasText: LD });
    const tn = await rowN.innerText(), td = await rowD.innerText();
    ok(/Night shift/.test(tn), tn); ok(/Early/.test(tn) && /4h 30m/.test(tn), 'early mark: ' + tn);
    ok(/Day shift/.test(td) && !/Early/.test(td), td);
  });
  await test('Daily report: the Shift filter keeps only the chosen shift', async () => {
    await page.selectOption('#cfShift', { label: 'Night shift' });
    await page.waitForFunction((L) => !document.getElementById('reportTable').innerText.includes(L), LD, { timeout: 10000 });
    ok((await page.locator('#reportTable').innerText()).includes(LN));
  });
  await test('no script errors', async () => { eq(errors, []); });

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
