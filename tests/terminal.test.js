// End-to-end tests of the punch terminal with the NEW login against the STAGING Supabase project (ROADMAP S3).
// Needs staging set up with supabase/staging-terminal-bundle.sql + the terminal Auth user (see that file's header).
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const KEY = 'test-terminal-key-1234';
const rid = Math.random().toString(36).slice(2, 7).toUpperCase();
const LABOR = 'TRM' + rid;

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined });
  const newCtx = async () => { const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, serviceWorkers: 'block' });
    await curlRoutes(ctx, /jsdelivr|supabase\.co/); await ctx.route(/justadudewhohacks/, r => r.abort()); return ctx; };
  const openTerminal = async (ctx, hash = '#key=' + KEY, query = '?client=TEST') => {
    const page = await ctx.newPage(); await page.goto(url + '/punch/index.html' + query + hash); return page; };
  const started = (page) => page.waitForFunction(() => document.getElementById('mainContainer').style.display === 'flex', null, { timeout: 45000 });

  // ---- admin side: test data (a department, an enrolled labor, a location)
  const adminCtx = await newCtx(); const admin = await adminCtx.newPage(); await admin.goto(url + '/tests/harness.html');
  await admin.waitForFunction(() => typeof AUTH !== 'undefined');
  const al = await admin.evaluate(() => AUTH.login('TEST', 'admin', 'Test@1234'));
  if (!al.success) { console.error('admin login failed - staging not set up? ' + JSON.stringify(al)); process.exit(2); }
  const setup = await admin.evaluate(async (LABOR) => {
    const cid = AUTH.getClientId(), r = LABOR.slice(3);
    const d = await supabaseClient.from('departments').insert({ name: 'TERM ' + r, code: 'T' + r, client_id: cid }).select().single();
    const iq = '8' + String(Math.floor(Math.random() * 1e9)).padStart(9, '0');
    await supabaseClient.from('iqama_registry').insert({ iqama_number: iq, labor_id: LABOR, client_id: cid });
    const l = await supabaseClient.from('laborers').insert({ labor_id: LABOR, iqama_number: iq, name: 'Terminal Test', nationality: 'X', date_of_joining: '2020-01-01', department_id: d.data.id, client_id: cid, face_enrolled: true, face_descriptor: [0.1, 0.2, 0.3], monthly_salary: 4321 });
    const loc = await supabaseClient.from('punch_locations').insert({ name: 'Gate ' + r, department_id: d.data.id, latitude: 1, longitude: 1, client_id: cid }).select().single();
    return { dept: d.data && d.data.id, labor: !l.error, loc: loc.data && loc.data.id, err: (d.error || l.error || loc.error || {}).message };
  }, LABOR);
  ok(setup.dept && setup.labor && setup.loc, 'test data setup failed: ' + JSON.stringify(setup));
  const adminRows = (sql) => admin.evaluate(async (L) => (await supabaseClient.from('punch_records').select('date,time,type,is_night_shift_end').eq('labor_id', L).order('date').order('time')).data, LABOR);

  console.log('Starting the terminal');
  const termCtx = await newCtx();
  await test('with the terminal key in the link: the terminal starts, shows the company, hides the key from the address bar', async () => {
    const page = await openTerminal(termCtx); await started(page);
    eq(await page.locator('#clientBadge').innerText(), 'Test Company');
    eq(await page.evaluate(() => window.location.hash), '', 'key removed from address');
    eq(await page.evaluate(() => localStorage.getItem('dawam_terminal_key')), KEY, 'key kept on this device');
    eq(await page.evaluate(() => TerminalAPI.active), true);
    await page.close();
  });
  await test('restarting the terminal without the key in the link works (session and key are kept on the device)', async () => {
    const page = await openTerminal(termCtx, ''); await started(page); await page.close();
  });
  await test('a wrong terminal key is refused with a clear message', async () => {
    const c = await newCtx(); const page = await openTerminal(c, '#key=wrong-key-123');
    await page.waitForFunction(() => document.getElementById('invalidClientScreen').classList.contains('active'), null, { timeout: 30000 });
    ok((await page.locator('#errorCode').innerText()).includes('Terminal key not accepted'), await page.locator('#errorCode').innerText());
    await c.close();
  });
  await test('no terminal key at all: the terminal asks for its link', async () => {
    const c = await newCtx(); const page = await openTerminal(c, '');
    await page.waitForFunction(() => document.getElementById('invalidClientScreen').classList.contains('active'), null, { timeout: 30000 });
    ok((await page.locator('#errorCode').innerText()).includes('needs its terminal key'), await page.locator('#errorCode').innerText());
    await c.close();
  });

  const term = await openTerminal(termCtx, ''); await started(term);

  console.log('\nWhat a terminal can and cannot do');
  await test('a terminal cannot read or write tables directly (salary, ID numbers, punches, settings ...)', async () => {
    const r = await term.evaluate(async () => {
      const out = {};
      for (const t of ['laborers', 'punch_records', 'settings', 'users', 'clients', 'departments', 'daily_attendance']) {
        const res = await supabaseClient.from(t).select('*').limit(1); out[t] = (res.data || []).length;
      }
      const sal = await supabaseClient.from('laborers').select('monthly_salary').limit(1);
      const ins = await supabaseClient.from('punch_records').insert({ labor_id: 'X', department_id: '00000000-0000-0000-0000-000000000000', date: '2020-01-01', time: '09:00', type: 'login' });
      return { out, salaryRefusedOrEmpty: !!sal.error || (sal.data || []).length === 0, insertRefused: !!ins.error };
    });
    for (const [t, n] of Object.entries(r.out)) eq(n, 0, t + ' rows visible to the terminal');
    ok(r.salaryRefusedOrEmpty && r.insertRefused, JSON.stringify(r));
  });
  await test('what the terminal downloads has no salary and no ID number', async () => {
    const r = await term.evaluate(async () => { const b = await TerminalAPI.bootstrap({ fresh: true }); const me = b.data.laborers.find(l => l.name === 'Terminal Test');
      return { found: !!me, keys: me ? Object.keys(me).sort() : [], hasLocations: b.data.locations.length >= 1, settings: !!b.data.settings }; });
    ok(r.found, 'test labor in the download'); eq(r.keys, ['department_id', 'face_descriptor', 'face_enrolled', 'labor_id', 'name'], 'fields');
    ok(r.hasLocations && r.settings);
  });
  await test('an administrator cannot use the terminal functions, a terminal cannot use administrator functions', async () => {
    const a = await admin.evaluate(async () => { const r = await supabaseClient.rpc('terminal_bootstrap'); return !!r.error; });
    const t = await term.evaluate(async () => { const r = await supabaseClient.rpc('register_iqama', { p_iqama: '7771110001' }); return !!r.error; });
    ok(a && t, JSON.stringify({ adminRefused: a, terminalRefused: t }));
  });

  console.log('\nPunching');
  const punch = (page, extra) => page.evaluate(async (a) => TerminalAPI.recordPunch(Object.assign({ laborId: a.L, type: 'login', locationName: 'Gate', confidence: 95, locationId: a.loc }, a.x)), { L: LABOR, loc: setup.loc, x: extra });
  const today = await term.evaluate(() => DateUtils.today());
  const dayShift = async (n) => term.evaluate((n) => { const d = new Date(); d.setUTCDate(d.getUTCDate() - n); return d.toISOString().split('T')[0]; }, n);
  await test('a punch is recorded; the same punch sent twice is stored once; attendance is calculated', async () => {
    const d = await dayShift(5);
    const a = await punch(term, { date: d, time: '09:00:00', type: 'login' });
    const b = await punch(term, { date: d, time: '09:00:00', type: 'login' });
    const c = await punch(term, { date: d, time: '18:30:00', type: 'logout' });
    ok(a.success && !a.data.duplicate, JSON.stringify(a)); ok(b.success && b.data.duplicate, JSON.stringify(b)); ok(c.success, JSON.stringify(c));
    const rows = (await adminRows()).filter(r => r.date === d); eq(rows.map(r => r.time), ['09:00:00', '18:30:00'], 'stored punches');
    const att = await admin.evaluate(async ([L, d]) => (await supabaseClient.from('daily_attendance').select('total_hours,auto_status').eq('labor_id', L).eq('date', d).maybeSingle()).data, [LABOR, d]);
    eq([Number(att.total_hours), att.auto_status], [9.5, 'P'], 'attendance');
  });
  await test('night shift: a 05:00 punch after a 21:00 punch belongs to the evening date', async () => {
    const d1 = await dayShift(4), d2 = await dayShift(3);
    await punch(term, { date: d1, time: '21:00:00', type: 'login' });
    const r = await punch(term, { date: d2, time: '05:00:00', type: 'logout' });
    ok(r.success && r.data.date === d1 && r.data.is_night_shift_end === true, JSON.stringify(r));
  });
  await test('punch state, next punch type and the daily limit', async () => {
    const d = await dayShift(5);
    const s = await term.evaluate(async ([L, d]) => ({ st: (await TerminalAPI.getPunchState(L, d)).data, next: await TerminalAPI.getNextPunchType(L), lim: await TerminalAPI.checkPunchLimit(L) }), [LABOR, d]);
    eq([Number(s.st.count), s.st.last_type], [2, 'logout'], 'state of the day with 2 punches');
    const today0 = await term.evaluate(async (L) => (await TerminalAPI.getPunchState(L)).data, LABOR);
    eq(Number(today0.count), 0, 'today has no punches yet');
    eq([s.next, s.lim.allowed], ['login', true], 'next type / allowed today');
    const list = await term.evaluate(async ([L, d]) => (await TerminalAPI.todayPunches(L, d)).data.map(p => p.type), [LABOR, d]);
    eq(list, ['login', 'logout'], 'list of the day');
  });
  await test('refused: unknown labor, wrong type, far-future date', async () => {
    const r1 = await term.evaluate(async () => TerminalAPI.recordPunch({ laborId: 'NO-SUCH', type: 'login', date: DateUtils.today(), time: '09:00:00' }));
    const r2 = await punch(term, { date: today, time: '09:00:00', type: 'hack' });
    const r3 = await punch(term, { date: '2099-01-01', time: '09:00:00' });
    ok(!r1.success && !r2.success && !r3.success, JSON.stringify([r1, r2, r3]));
  });
  await test('a punch made offline is uploaded later through the terminal functions (and only marked as sent once accepted)', async () => {
    const d = await dayShift(2);
    const out = await term.evaluate(async ([L, d, loc]) => {
      await OfflineStorage.init();
      await OfflineStorage.savePunch({ laborId: L, departmentId: null, date: d, time: '08:15:00', type: 'login', locationId: loc, locationName: 'Gate', confidence: 90, clientId: CLIENT_SESSION.clientId });
      const before = (await OfflineStorage.getUnsyncedPunches()).filter(p => p.laborId === L).length;
      await SyncManager.syncPunches();
      const after = (await OfflineStorage.getUnsyncedPunches()).filter(p => p.laborId === L).length;
      return { before, after };
    }, [LABOR, d, setup.loc]);
    eq(out, { before: 1, after: 0 }, 'unsent punches before / after');
    ok((await adminRows()).some(r => r.date === d && r.time === '08:15:00'), 'the punch reached the database');
  });
  await test('3 weak face matches flag the labor for re-enrollment', async () => {
    const r = await term.evaluate(async (L) => { await TerminalAPI.lowConfidence(L); await TerminalAPI.lowConfidence(L); return TerminalAPI.lowConfidence(L); }, LABOR);
    eq(r.needsReenrollment, true);
  });

  // ---- cleanup (admin)
  await admin.evaluate(async ([L, dept, loc]) => {
    await supabaseClient.from('punch_records').delete().eq('labor_id', L);
    await supabaseClient.from('daily_attendance').delete().eq('labor_id', L);
    await supabaseClient.from('lop_requests').delete().eq('labor_id', L);
    await supabaseClient.from('laborers').delete().eq('labor_id', L);
    await supabaseClient.from('iqama_registry').delete().eq('labor_id', L);
    await supabaseClient.from('punch_locations').delete().eq('id', loc);
    await supabaseClient.from('departments').delete().eq('id', dept);
  }, [LABOR, setup.dept, setup.loc]);

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
