// BASELINE tests: record how the app behaves TODAY (roadmap task 1), against the STAGING Supabase project.
// Tests marked "documents known issue" pass because they describe current behaviour that we intend to change.
// When a fix lands, such a test is flipped to expect the fixed behaviour.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');

const STAGING_REF = 'jbfdaeyqsszoacrijldk';
const EXT = /jsdelivr|supabase\.co/;
const rid = () => Math.random().toString(36).slice(2, 8).toUpperCase();

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: require('fs').existsSync(exe) ? exe : undefined });
  const newPage = async (opts = {}) => {
    const ctx = await browser.newContext(opts);
    await curlRoutes(ctx, EXT);
    const page = await ctx.newPage();
    if (opts._clock) await page.clock.install({ time: opts._clock });
    await page.goto(url + '/tests/harness.html');
    await page.waitForFunction(() => typeof supabaseClient !== 'undefined' && typeof PunchAPI !== 'undefined' && typeof SyncManager !== 'undefined');
    return { ctx, page };
  };

  const { page } = await newPage();
  // SAFETY: never run against the live project
  const target = await page.evaluate(() => SUPABASE_URL);
  if (!target.includes(STAGING_REF)) { console.error('REFUSING to run: not pointed at staging: ' + target); process.exit(2); }
  console.log('Running against staging:', target, '\n');

  const created = { depts: [], labors: [] };
  const mkLabor = async () => page.evaluate(async () => {
    const r = Math.random().toString(36).slice(2, 8).toUpperCase();
    const cid = AUTH.getClientId();
    const d = await supabaseClient.from('departments').insert({ name: 'TEST ' + r, code: 'T' + r, client_id: cid }).select().single();
    if (d.error) throw new Error('dept: ' + d.error.message);
    const laborId = 'TST' + r, iq = '9' + String(Math.floor(Math.random() * 1e9)).padStart(9, '0');
    let e = await supabaseClient.from('iqama_registry').insert({ iqama_number: iq, labor_id: laborId, client_id: cid });
    if (e.error) throw new Error('iqama: ' + e.error.message);
    e = await supabaseClient.from('laborers').insert({ labor_id: laborId, iqama_number: iq, name: 'Test ' + r, nationality: 'X', date_of_joining: '2020-01-01', department_id: d.data.id, client_id: cid });
    if (e.error) throw new Error('laborer: ' + e.error.message);
    return { laborId, deptId: d.data.id, iq };
  });
  const punch = (L, date, time, type) => page.evaluate(([L, date, time, type]) =>
    PunchAPI.savePunch({ laborId: L.laborId, departmentId: L.deptId, date, time, type, locationId: null, locationName: 'T', confidence: 99, photoUrl: null }), [L, date, time, type]);
  const rows = (L) => page.evaluate(async (id) => (await supabaseClient.from('punch_records').select('date,time,type,is_night_shift_end').eq('labor_id', id).order('date').order('time')).data, L.laborId);
  const recalc = async (L, date) => page.evaluate(async ([id, date]) => {
    await new Promise(r => setTimeout(r, 800));            // savePunch fires the recalculation without waiting
    await supabaseClient.rpc('update_daily_attendance', { p_labor_id: id, p_date: date });
    return (await supabaseClient.from('daily_attendance').select('first_login,last_logout,total_hours,auto_status').eq('labor_id', id).eq('date', date).maybeSingle()).data;
  }, [L.laborId, date]);

  console.log('Login');
  await test('admin login succeeds with correct company code, username, password', async () => {
    const r = await page.evaluate(() => AUTH.login('TEST', 'admin', 'Test@1234'));
    ok(r.success, JSON.stringify(r)); eq(r.user.role, 'admin', 'role');
  });
  await test('wrong password is rejected', async () => {
    const r = await page.evaluate(() => AUTH.login('TEST', 'admin', 'wrong'));
    eq(r.success, false, 'success'); eq(r.error, 'Invalid password', 'error');
  });
  await test('wrong company code is rejected', async () => {
    const r = await page.evaluate(() => AUTH.login('NOPE', 'admin', 'Test@1234'));
    eq(r.success, false, 'success'); eq(r.error, 'Invalid client code', 'error');
  });
  await test('same admin can be logged in on two devices at once', async () => {
    const a = await newPage(), b = await newPage();
    const ra = await a.page.evaluate(() => AUTH.login('TEST', 'admin', 'Test@1234'));
    const rb = await b.page.evaluate(() => AUTH.login('TEST', 'admin', 'Test@1234'));
    ok(ra.success && rb.success, 'both logins should succeed');
    const stillA = await a.page.evaluate(() => !!localStorage.getItem('ak_attendance_session'));
    ok(stillA, 'first device session must survive second login');
    await a.ctx.close(); await b.ctx.close();
  });

  console.log('\nPunch type and limits');
  await test('punch type alternates login/logout through the day', async () => {
    const L = await mkLabor(); created.labors.push(L);
    const today = await page.evaluate(() => DateUtils.today());
    eq(await page.evaluate(id => PunchAPI.getNextPunchType(id), L.laborId), 'login', 'first');
    await punch(L, today, '08:00:00', 'login');
    eq(await page.evaluate(id => PunchAPI.getNextPunchType(id), L.laborId), 'logout', 'second');
    await punch(L, today, '17:00:00', 'logout');
    eq(await page.evaluate(id => PunchAPI.getNextPunchType(id), L.laborId), 'login', 'third');
  });
  await test('punch limit per day (setting max_punches_per_day = 4) blocks the 5th punch', async () => {
    const L = await mkLabor(); created.labors.push(L);
    const today = await page.evaluate(() => DateUtils.today());
    for (const t of ['08:00:00', '09:00:00', '10:00:00']) await punch(L, today, t, 'login');
    const three = await page.evaluate(id => PunchAPI.checkPunchLimit(id), L.laborId);
    eq([three.allowed, three.current, three.max], [true, 3, 4], 'after 3');
    await punch(L, today, '11:00:00', 'login');
    const four = await page.evaluate(id => PunchAPI.checkPunchLimit(id), L.laborId);
    eq([four.allowed, four.current], [false, 4], 'after 4');
  });
  await test('NO minimum gap today: a second punch one minute after the first is stored', async () => {
    const L = await mkLabor(); created.labors.push(L);
    await punch(L, '2020-03-02', '09:00:00', 'login');
    await punch(L, '2020-03-02', '09:01:00', 'logout');
    eq((await rows(L)).map(r => r.time), ['09:00:00', '09:01:00'], 'both stored');
  }, { knownIssue: 'no 4-hour lock yet (roadmap tasks 21-23)' });
  await test('savePunch stores the punch but reports success:false ("rpc(...).catch is not a function")', async () => {
    const L = await mkLabor(); created.labors.push(L);
    const r = await punch(L, '2020-03-02', '10:00:00', 'login');
    eq(r.success, false, 'success flag');
    ok(/catch is not a function/.test(r.error), 'error text: ' + r.error);
    eq((await rows(L)).length, 1, 'punch is nevertheless in the database');
  }, { knownIssue: 'new finding 53 - online punches look failed, get saved again offline, daily attendance only updates through the offline sync path' });

  console.log('\nNight shift date logic (settings: start 20:00, end 06:30)');
  await test('day punches keep their own date and are not flagged night', async () => {
    const L = await mkLabor(); created.labors.push(L);
    await punch(L, '2020-03-03', '09:00:00', 'login'); await punch(L, '2020-03-03', '18:30:00', 'logout');
    eq(await rows(L), [
      { date: '2020-03-03', time: '09:00:00', type: 'login', is_night_shift_end: false },
      { date: '2020-03-03', time: '18:30:00', type: 'logout', is_night_shift_end: false }]);
  });
  await test('05:00 punch after a 21:00 punch the day before is stored on the previous date, flagged as night end', async () => {
    const L = await mkLabor(); created.labors.push(L);
    await punch(L, '2020-03-04', '21:00:00', 'login'); await punch(L, '2020-03-05', '05:00:00', 'logout');
    eq(await rows(L), [
      { date: '2020-03-04', time: '05:00:00', type: 'logout', is_night_shift_end: true },
      { date: '2020-03-04', time: '21:00:00', type: 'login', is_night_shift_end: false }]);
  });
  await test('05:00 punch with NO night punch the day before stays on its own date', async () => {
    const L = await mkLabor(); created.labors.push(L);
    await punch(L, '2020-03-06', '05:00:00', 'login');
    eq((await rows(L)).map(r => [r.date, r.is_night_shift_end]), [['2020-03-06', false]]);
  });
  await test('boundary: 06:30 counts as night end, 06:31 does not', async () => {
    const L = await mkLabor(); created.labors.push(L);
    await punch(L, '2020-03-07', '21:00:00', 'login');
    await punch(L, '2020-03-08', '06:30:00', 'logout');
    await punch(L, '2020-03-08', '06:31:00', 'login');
    eq((await rows(L)).map(r => [r.date, r.time, r.is_night_shift_end]), [
      ['2020-03-07', '06:30:00', true], ['2020-03-07', '21:00:00', false], ['2020-03-08', '06:31:00', false]]);
  });

  console.log('\nDaily attendance calculation');
  await test('day shift 09:00-18:30 = 9.5 hours, status P', async () => {
    const L = await mkLabor(); created.labors.push(L);
    await punch(L, '2020-03-09', '09:00:00', 'login'); await punch(L, '2020-03-09', '18:30:00', 'logout');
    const r = await recalc(L, '2020-03-09');
    eq([r.first_login, r.last_logout, Number(r.total_hours), r.auto_status], ['09:00:00', '18:30:00', 9.5, 'P']);
  });
  await test('night shift 21:00-05:00 is stored as 16 hours (should be 8)', async () => {
    const L = await mkLabor(); created.labors.push(L);
    await punch(L, '2020-03-10', '21:00:00', 'login'); await punch(L, '2020-03-11', '05:00:00', 'logout');
    const r = await recalc(L, '2020-03-10');
    eq([r.first_login, r.last_logout, Number(r.total_hours)], ['05:00:00', '21:00:00', 16], 'current (wrong) values');
  }, { knownIssue: 'roadmap finding 48 - night shift hours wrong in daily_attendance' });

  console.log('\nOffline storage and sync');
  await test('offline punch is saved on the device, then uploaded; night-end date is corrected; no duplicate on second sync', async () => {
    const L = await mkLabor(); created.labors.push(L);
    await punch(L, '2020-03-12', '21:00:00', 'login');                    // evening punch already on the server
    const out = await page.evaluate(async (L) => {
      await OfflineStorage.init();
      const cid = AUTH.getClientId();
      await OfflineStorage.savePunch({ laborId: L.laborId, departmentId: L.deptId, date: '2020-03-13', time: '05:00:00', type: 'logout', locationId: null, locationName: 'T', confidence: 99, clientId: cid });
      const before = (await OfflineStorage.getUnsyncedPunches()).filter(p => p.laborId === L.laborId).length;
      await SyncManager.syncPunches();
      const after = (await OfflineStorage.getUnsyncedPunches()).filter(p => p.laborId === L.laborId).length;
      await SyncManager.syncPunches();
      return { before, after };
    }, L);
    eq(out, { before: 1, after: 0 }, 'unsynced count before/after');
    eq((await rows(L)).map(r => [r.date, r.time, r.is_night_shift_end]), [['2020-03-12', '05:00:00', true], ['2020-03-12', '21:00:00', false]]);
  });

  console.log('\nDate and time handling');
  await test('at 01:00 Riyadh time the app records YESTERDAY\'s date (date is UTC-based, time is local)', async () => {
    const t = await newPage({ timezoneId: 'Asia/Riyadh', _clock: new Date('2026-10-01T22:00:00Z') });   // = 2026-10-02 01:00 in Riyadh
    const v = await t.page.evaluate(() => [DateUtils.today(), DateUtils.now()]);
    eq(v, ['2026-10-01', '01:00:00'], 'today/now');
    await t.ctx.close();
  }, { knownIssue: 'new finding 52 - date/time mismatch between local midnight and UTC midnight' });

  // cleanup
  await page.evaluate(async (c) => {
    const ids = c.labors.map(l => l.laborId);
    for (const t of ['punch_records', 'daily_attendance', 'lop_requests']) await supabaseClient.from(t).delete().in('labor_id', ids);
    await supabaseClient.from('laborers').delete().in('labor_id', ids);
    await supabaseClient.from('iqama_registry').delete().in('labor_id', ids);
    await supabaseClient.from('departments').delete().in('id', c.labors.map(l => l.deptId));
  }, created);

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
