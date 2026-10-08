// The "My attendance" month screen on the punch terminal (current + previous month), against the STAGING project (needs migration 008 there).
// The face check is replaced by a stand-in; everything else (data download, month function, punches list) is real.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const KEY = 'test-terminal-key-1234';
const rid = Math.random().toString(36).slice(2, 7).toUpperCase();
const LABOR = 'TRM' + rid;
const FACE0 = Math.round((0.5 + Math.floor(Math.random() * 9000) / 20000) * 1e5) / 1e5;   // unique per run, so labors left by earlier runs never match
const pad = n => String(n).padStart(2, '0');
const ymd = d => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined, args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'] });
  const newCtx = async (extra = {}) => { const ctx = await browser.newContext(Object.assign({ viewport: { width: 390, height: 844 }, serviceWorkers: 'block' }, extra));
    await curlRoutes(ctx, /jsdelivr|supabase\.co/); await ctx.route(/justadudewhohacks/, r => r.abort()); return ctx; };

  // ---- admin side: test data (a department, an enrolled labor, a location)
  const adminCtx = await newCtx(); const admin = await adminCtx.newPage(); await admin.goto(url + '/tests/harness.html');
  await admin.waitForFunction(() => typeof AUTH !== 'undefined');
  const al = await admin.evaluate(() => AUTH.login('TEST', 'admin', 'Test@1234'));
  if (!al.success) { console.error('admin login failed - staging not set up? ' + JSON.stringify(al)); process.exit(2); }
  await admin.evaluate((f) => { window.__F0 = f; }, FACE0);
  const setup = await admin.evaluate(async (LABOR) => {
    const cid = AUTH.getClientId(), r = LABOR.slice(3);
    const d = await supabaseClient.from('departments').insert({ name: 'TERM ' + r, code: 'T' + r, client_id: cid }).select().single();
    const iq = '8' + String(Math.floor(Math.random() * 1e9)).padStart(9, '0');
    await supabaseClient.from('iqama_registry').insert({ iqama_number: iq, labor_id: LABOR, client_id: cid });
    const l = await supabaseClient.from('laborers').insert({ labor_id: LABOR, iqama_number: iq, name: 'Terminal Test', nationality: 'X', date_of_joining: '2020-01-01', department_id: d.data.id, client_id: cid, face_enrolled: true, face_descriptor: [window.__F0, 0.11, 0.55], monthly_salary: 4321 });
    const loc = await supabaseClient.from('punch_locations').insert({ name: 'Gate ' + r, department_id: d.data.id, latitude: 1, longitude: 1, client_id: cid }).select().single();
    return { dept: d.data && d.data.id, labor: !l.error, loc: loc.data && loc.data.id, err: (d.error || l.error || loc.error || {}).message };
  }, LABOR);
  ok(setup.dept && setup.labor && setup.loc, 'test data setup failed: ' + JSON.stringify(setup));

  // attendance rows: this month day 1 = P, day 2 = H, day 3 = A; holiday on day 5; previous month: one P
  const now = new Date(), thisStart = new Date(now.getFullYear(), now.getMonth(), 1), prevDay = new Date(now.getFullYear(), now.getMonth() - 1, 10);
  const rows = await admin.evaluate(async (a) => {
    const cid = AUTH.getClientId();
    const mk = (date, fi, lo, h, st) => ({ labor_id: a.L, department_id: a.dept, date, first_login: fi, last_logout: lo, total_hours: h, auto_status: st, client_id: cid });
    const r1 = await supabaseClient.from('daily_attendance').insert([mk(a.d1, '06:00', '16:00', 10, 'P'), mk(a.d2, '06:00', '10:00', 4, 'H'), mk(a.d3, null, null, 0, 'A'), mk(a.prev, '06:00', '15:00', 9, 'P')]);
    // day 1: IN 06:15, OUT 10:30, IN 11:00, OUT 16:00 (two sessions)
    const r3 = await supabaseClient.from('punch_records').insert([
      { labor_id: a.L, department_id: a.dept, date: a.d1, time: '06:15:00', type: 'login', location_name: 'Gate', client_id: cid, photo_url: cid + '/punches/' + a.L + '_1.jpg' },
      { labor_id: a.L, department_id: a.dept, date: a.d1, time: '10:30:00', type: 'logout', location_name: 'Gate', client_id: cid },
      { labor_id: a.L, department_id: a.dept, date: a.d1, time: '11:00:00', type: 'login', location_name: 'Gate', client_id: cid },
      { labor_id: a.L, department_id: a.dept, date: a.d1, time: '16:00:00', type: 'logout', location_name: 'Gate', client_id: cid }]);
    if (r3.error) return { e1: r3.error.message };
    // day 7: approved by the administrator, no punches at all.  day 8: an OUT (03:03) punched BEFORE the IN (12:23), no OUT after the IN
    const ap = await supabaseClient.from('daily_attendance').insert({ labor_id: a.L, department_id: a.dept, date: a.d7, first_login: null, last_logout: null, total_hours: 0, auto_status: 'A', final_status: 'P', approved_by: 'Admin Name', client_id: cid });
    if (ap.error) return { e1: ap.error.message };
    const o1 = await supabaseClient.from('punch_records').insert({ labor_id: a.L, department_id: a.dept, date: a.d8, time: '03:03:00', type: 'logout', location_name: 'Gate', client_id: cid });
    const o2 = await supabaseClient.from('punch_records').insert({ labor_id: a.L, department_id: a.dept, date: a.d8, time: '12:23:00', type: 'login', location_name: 'Gate', client_id: cid });
    if (o1.error || o2.error) return { e1: (o1.error || o2.error).message };
    const r2 = await supabaseClient.from('holidays').upsert({ client_id: cid, date: a.hol, name: 'Test holiday' }, { onConflict: 'client_id,date' });
    return { e1: r1.error && r1.error.message, e2: r2.error && r2.error.message };
  }, { L: LABOR, dept: setup.dept, d1: ymd(thisStart), d2: ymd(new Date(thisStart.getTime() + 86400000 * 1)), d3: ymd(new Date(thisStart.getTime() + 86400000 * 2)), hol: ymd(new Date(thisStart.getTime() + 86400000 * 4)), d7: ymd(new Date(thisStart.getFullYear(), thisStart.getMonth(), 7)), d8: ymd(new Date(thisStart.getFullYear(), thisStart.getMonth(), 8)), prev: ymd(prevDay) });
  ok(!rows.e1 && !rows.e2, 'attendance setup failed: ' + JSON.stringify(rows));

  const ctx = await newCtx({ geolocation: { latitude: 1, longitude: 1 }, permissions: ['geolocation', 'camera'] });
  const page = await ctx.newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.goto(url + '/punch/index.html?client=TEST#key=' + KEY);
  await page.waitForFunction(() => document.getElementById('mainContainer').style.display === 'flex', null, { timeout: 45000 });
  await page.waitForFunction((L) => allLaborers.some(l => l.labor_id === L), LABOR, { timeout: 20000 });
  await page.waitForFunction(() => !document.getElementById('statusOverlay').classList.contains('active'), null, { timeout: 15000 }).catch(() => {});
  // stand-in for the face check: only the test labor's face matches
  await page.evaluate((f0) => {
    modelsLoaded = true;
    window.faceapi = { TinyFaceDetectorOptions: function () {},
      euclideanDistance: (a, b) => (Math.abs(a[0] - f0) < 0.00002 ? 0.05 : 0.9),
      detectSingleFace: () => ({ withFaceLandmarks: () => ({ withFaceDescriptor: async () => ({ descriptor: new Float32Array([f0, 0.11, 0.55]) }) }) }) };
  }, FACE0);

  console.log('My attendance');
  await test('"View my attendance" identifies the labor and shows this month: name, title, totals, letters on the days', async () => {
    await page.click('.view-attendance-link');
    await page.waitForFunction(() => document.getElementById('attendanceModal').classList.contains('active') && document.querySelectorAll('#calGrid .cal-day').length > 0, null, { timeout: 30000 });
    ok(new RegExp(LABOR).test(await page.locator('#attendanceInfo').innerText()), 'the screen shows this labor: ' + await page.locator('#attendanceInfo').innerText());
    eq(await page.locator('#monthTitle').innerText(), now.toLocaleDateString('en-US', { month: 'long', year: 'numeric' }));
    eq(await page.locator('#monthTotals').count(), 0); eq(await page.locator('.cal-legend').count(), 0);   // no totals tiles, no legend, no letters on the days
    // green = full hours (day 1) or approved (day 7); red = short hours (day 2) or absent (day 3); grey = holiday
    eq(await page.locator('#calGrid .cal-day.p').count(), 2); eq(await page.locator('#calGrid .cal-day.h').count(), 0);
    eq(await page.locator('#calGrid .cal-day.a').count(), 2); eq(await page.locator('#calGrid .cal-day.o').count(), 1);
    eq(await page.locator('#calGrid .cal-day small').count(), 0);
  });
  await test('tapping a day shows its punches as two tiles per row, and the worked hours next to the date', async () => {
    await page.click('#calGrid .cal-day[data-date="' + ymd(thisStart) + '"]');
    await page.waitForFunction(() => document.querySelectorAll('#attendanceList .punch-item').length === 4, null, { timeout: 15000 }).catch(async () => { throw new Error('list shows: ' + JSON.stringify(await page.locator('#attendanceList').innerText()) + ' title: ' + await page.locator('#dayTitle').innerText()); });
    const txt = await page.locator('#attendanceList').innerText();
    ok(/06:15|6:15/.test(txt) && /4:00|16:00/.test(txt), txt);
    const tops = await page.evaluate(() => [...document.querySelectorAll('#attendanceList .punch-item')].map(e => Math.round(e.getBoundingClientRect().top)));
    ok(tops[0] === tops[1] && tops[2] === tops[3] && tops[2] > tops[0], '2 x 2 tiles: ' + JSON.stringify(tops));
    const title = await page.locator('#dayTitle').innerText();
    ok(/9h 45m worked/.test(title), 'first IN 06:15 to last OUT 16:00 = 9h 45m: ' + JSON.stringify(title));
  });
  await test('tapping a punch tile with a photo opens the photo full screen (once); tapping the photo closes it; a tile without a photo does nothing', async () => {
    await page.evaluate(() => { window.__opened = 0; PhotoURL.resolve = async () => { window.__opened++; return 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'; }; });
    await page.locator('#attendanceList .punch-item.has-photo').first().click();
    await page.waitForFunction(() => document.getElementById('fullscreenPhoto').classList.contains('active'), null, { timeout: 5000 });
    eq(await page.evaluate(() => window.__opened), 1);
    await page.click('#fullscreenPhoto', { position: { x: 10, y: 10 } });
    await page.waitForFunction(() => !document.getElementById('fullscreenPhoto').classList.contains('active'), null, { timeout: 5000 });
    await page.locator('#attendanceList .punch-item:not(.has-photo)').first().click();
    await page.waitForTimeout(300);
    ok(!(await page.evaluate(() => document.getElementById('fullscreenPhoto').classList.contains('active'))), 'a tile without photo must not open anything');
  });
  await test('a day approved by the administrator is green like a worked day and shows no remark', async () => {
    const d7 = ymd(new Date(thisStart.getFullYear(), thisStart.getMonth(), 7));
    const cell = page.locator('#calGrid .cal-day[data-date="' + d7 + '"]');
    ok(/\bp\b/.test(await cell.getAttribute('class')), 'cell: ' + await cell.getAttribute('class'));
    await cell.click();
    await page.waitForFunction(() => /No punches/.test(document.getElementById('attendanceList').innerText), null, { timeout: 15000 });
    ok(!/pprove/.test(await page.locator('#dayTitle').innerText() + await page.locator('#attendanceList').innerText()), 'no approval remark');
  });
  await test('an OUT punched before the IN is not counted as hours: the day does not say "0h 0m worked"', async () => {
    const d8 = ymd(new Date(thisStart.getFullYear(), thisStart.getMonth(), 8));
    await page.click('#calGrid .cal-day[data-date="' + d8 + '"]');
    await page.waitForFunction(() => document.querySelectorAll('#attendanceList .punch-item').length === 2, null, { timeout: 15000 });
    const t = await page.locator('#dayTitle').innerText();
    ok(!/0h 0m/.test(t) && !/No OUT punch/.test(t), t);
  });
  await test('the Close button shows the whole word "Close" (not cut off)', async () => {
    const c = await page.evaluate(() => { const e = document.querySelector('.attendance-close'), b = e.getBoundingClientRect(); return { w: b.width, scrollW: e.scrollWidth, right: b.right, vw: window.innerWidth }; });
    ok(c.scrollW <= Math.ceil(c.w) + 1 && c.right <= c.vw, JSON.stringify(c));
  });
  await test('the next-month button is off (nothing after this month); the previous month opens with its own data', async () => {
    ok(await page.locator('#monthNext').isDisabled()); ok(await page.locator('#monthPrev').isEnabled());
    await page.click('#monthPrev');
    const prev = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    await page.waitForFunction((t) => document.getElementById('monthTitle').innerText === t && document.querySelectorAll('#calGrid .cal-day.p').length === 1, prev.toLocaleDateString('en-US', { month: 'long', year: 'numeric' }), { timeout: 15000 });
    ok(await page.locator('#monthPrev').isDisabled(), 'no month before the previous one'); ok(await page.locator('#monthNext').isEnabled());
  });
  await test('Close brings the punch screen back (ID box and IN / OUT visible, modal hidden)', async () => {
    await page.click('.attendance-close');
    await page.waitForFunction(() => !document.getElementById('attendanceModal').classList.contains('active'));
    ok(await page.locator('#inBtn').isVisible() && await page.locator('#outBtn').isVisible() && await page.locator('#laborIdInput').isVisible());
  });
  await test('the database refuses a month older than the previous one (even if asked directly)', async () => {
    const r = await page.evaluate(async (L) => { const d = new Date(); d.setMonth(d.getMonth() - 3); return TerminalAPI.monthAttendance(L, d.toISOString().slice(0, 10)); }, LABOR);
    ok(!r.success && /month not available/.test(r.error), JSON.stringify(r));
  });
  await test('no script errors during all of this', async () => { eq(errors, []); });

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
