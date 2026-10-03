// Tests of the new punch terminal screen (IN / OUT buttons, result screens, repeat / mismatch messages) against the STAGING project.
// The face check itself is replaced by a stand-in (the real one needs a camera): everything else (login, data download, location check, saving) is real.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const KEY = 'test-terminal-key-1234';
const rid = Math.random().toString(36).slice(2, 7).toUpperCase();
const LABOR = 'TRM' + rid;
const JPEG_B64 = require('fs').readFileSync(__dirname + '/photos.test.js', 'utf8').match(/JPEG_B64 = '([^']+)'/)[1];

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
  const adminRows = () => admin.evaluate(async (L) => (await supabaseClient.from('punch_records').select('date,time,type').eq('labor_id', L).order('date').order('time')).data, LABOR);

  const ctx = await newCtx({ geolocation: { latitude: 1, longitude: 1 }, permissions: ['geolocation', 'camera'] });
  const page = await ctx.newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.goto(url + '/punch/index.html?client=TEST#key=' + KEY);
  await page.waitForFunction(() => document.getElementById('mainContainer').style.display === 'flex', null, { timeout: 45000 });
  await page.waitForFunction(() => window.userCoords, null, { timeout: 20000 });
  await page.waitForFunction((L) => allLaborers.some(l => l.labor_id === L), LABOR, { timeout: 20000 });
  await page.waitForFunction(() => !document.getElementById('statusOverlay').classList.contains('active'), null, { timeout: 15000 });
  // stand-ins for the face check
  await page.evaluate((b64) => {
    modelsLoaded = true;
    PhotoUtils.capturePhoto = async () => { const bin = atob(b64), u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return { canvas: document.createElement('canvas'), blob: new Blob([u], { type: 'image/jpeg' }) }; };
    window.faceapi = { TinyFaceDetectorOptions: function () {}, euclideanDistance: () => 0.05,
      detectSingleFace: () => ({ withFaceLandmarks: () => ({ withFaceDescriptor: async () => ({ descriptor: new Float32Array([0.1, 0.2, 0.3]) }) }) }) };
  }, JPEG_B64);
  const ov = () => page.evaluate(() => { const o = document.getElementById('statusOverlay'); return { active: o.classList.contains('active'), cls: o.className, title: document.getElementById('statusTitle').textContent, details: document.getElementById('statusDetails').textContent }; });
  const press = async (id, labor) => { await page.fill('#laborIdInput', labor); await page.click(id); };
  const waitResult = async (cls) => { try { await waitResult0(cls); } catch (e) { const o = await ov(); throw new Error('expected ' + cls + ' but screen is: ' + JSON.stringify(o)); } };
  const waitResult0 = (cls) => page.waitForFunction((c) => { const o = document.getElementById('statusOverlay'); return o.classList.contains('active') && o.classList.contains(c); }, cls, { timeout: 15000 });
  const waitClosed = () => page.waitForFunction(() => !document.getElementById('statusOverlay').classList.contains('active'), null, { timeout: 12000 });

  console.log('Screen');
  await test('the screen has an ID box and IN / OUT buttons; no on-screen keypad and no old round PUNCH button', async () => {
    eq(await page.locator('#inBtn').count() + await page.locator('#outBtn').count(), 2);
    eq(await page.locator('#punchBtn').count(), 0);
    eq(await page.locator('.key').count(), 0);
    eq(await page.getAttribute('#laborIdInput', 'type'), 'text');
  });

  console.log('\nPunching');
  await test('OUT before any IN is refused with a clear message and nothing is recorded', async () => {
    await press('#outBtn', LABOR); await waitResult('k-warn');
    const o = await ov(); ok(/punch IN first/i.test(o.title), JSON.stringify(o));
    eq((await adminRows()).length, 0);
    await waitClosed();
  });
  await test('the ID box and the buttons sit in the middle over the oval; after IN they go away and only the oval stays, with a countdown', async () => {
    const mid = await page.evaluate(() => { const c = document.querySelector('.camera-section').getBoundingClientRect(), p = document.getElementById('idInputPanel').getBoundingClientRect(), g = document.getElementById('faceGuide').getBoundingClientRect();
      return { camMid: (c.top + c.bottom) / 2, panelMid: (p.top + p.bottom) / 2, ovalMid: (g.top + g.bottom) / 2 }; });
    ok(Math.abs(mid.panelMid - mid.camMid) < 40, 'ID box is not in the middle: ' + JSON.stringify(mid));
    ok(Math.abs(mid.ovalMid - mid.camMid) < 40, 'oval is not in the middle: ' + JSON.stringify(mid));
    await page.fill('#laborIdInput', LABOR); await page.click('#inBtn');
    await page.waitForFunction(() => document.getElementById('idInputPanel').classList.contains('hidden') && document.getElementById('faceStage').classList.contains('on'), null, { timeout: 5000 });
    const st = await page.evaluate(() => ({ oval: getComputedStyle(document.getElementById('faceGuide')).display, panel: getComputedStyle(document.getElementById('idInputPanel')).display, text: document.getElementById('faceStage').innerText }));
    eq(st.panel, 'none'); ok(st.oval !== 'none', 'oval must stay'); ok(/Look into the oval/.test(st.text), st.text);
  });
  await test('IN is recorded: green screen "Punched IN" with the name; one record', async () => {
    await waitResult('k-success');
    const o = await ov(); ok(/Punched IN/.test(o.title) && /Terminal Test/.test(o.details) && /Day shift/.test(o.details), JSON.stringify(o));
    const rows = await adminRows(); eq(rows.map(r => r.type), ['login']);
  });
  await test('the punch keeps its photo: the record holds the photo path and the file exists (v90 broke this silently)', async () => {
    const r = await admin.evaluate(async (L) => {
      const row = (await supabaseClient.from('punch_records').select('photo_url').eq('labor_id', L).eq('type', 'login').single()).data;
      const sig = row && row.photo_url ? await supabaseClient.storage.from('punch-photos').createSignedUrl(row.photo_url, 60) : null;
      return { path: row && row.photo_url, signed: !!(sig && sig.data && sig.data.signedUrl) };
    }, LABOR);
    ok(r.path && /^[0-9a-f-]{36}\/punches\/.+\.jpg$/.test(r.path), 'photo_url: ' + r.path);
    ok(r.signed, 'photo file can be opened');
  });
  await test('the result screen closes by itself after about 7 seconds and the ID box is cleared', async () => {
    const t0 = Date.now(); await waitClosed(); const secs = (Date.now() - t0) / 1000;
    ok(secs > 4 && secs < 10, 'closed after ' + secs + 's');
    eq(await page.inputValue('#laborIdInput'), '');
    ok(await page.locator('#inBtn').isEnabled(), 'buttons enabled again');
  });
  await test('OUT right after the IN (less than 4 hours) is refused with "You have logged in for the day"; nothing new is stored', async () => {
    await press('#outBtn', LABOR); await waitResult('k-warn');
    const o = await ov(); ok(/logged in for the day/i.test(o.title) && !/4/.test(o.title + o.details), 'message must not mention the 4 hours: ' + JSON.stringify(o));
    eq((await adminRows()).length, 1); await waitClosed();
  });
  await test('IN again the same day: "You have logged in for the day", nothing new is recorded', async () => {
    await press('#inBtn', LABOR); await waitResult('k-warn');
    const o = await ov(); ok(/logged in for the day/i.test(o.title), JSON.stringify(o));
    eq((await adminRows()).length, 1); await waitClosed();
  });
  await test('OUT 5 hours after the IN asks "Leaving early?"; Stay records nothing', async () => {
    // move the stored IN back by 5 hours (as the administrator), as if the labor had been at work since then
    const moved = await admin.evaluate(async (L) => {
      const d = new Date(Date.now() - 5 * 3600 * 1000), p2 = n => String(n).padStart(2, '0');
      const date = d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate()), time = p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':00';
      const r = await supabaseClient.from('punch_records').update({ date, time }).eq('labor_id', L).select();
      return { n: (r.data || []).length, err: r.error && r.error.message };
    }, LABOR);
    eq(moved.n, 1, JSON.stringify(moved));
    await press('#outBtn', LABOR); await waitResult('k-warn');
    const o = await ov(); ok(/Leaving early/.test(o.title) && /5h 0\dm/.test(o.details) && /9h 30m/.test(o.details) && /4h/.test(o.details), JSON.stringify(o));
    ok(await page.locator('#earlyStay').isVisible() && await page.locator('#earlyLeave').isVisible(), 'Stay and Leave now buttons');
    await page.click('#earlyStay');
    await waitClosed();
    eq((await adminRows()).length, 1); eq(await page.inputValue('#laborIdInput'), '');
  });
  await test('OUT again and "Leave now": the red "Punched OUT" screen with "Bye bye"; the OUT is stored as an early leave', async () => {
    await press('#outBtn', LABOR); await waitResult('k-warn'); await page.click('#earlyLeave');
    await waitResult('k-out');
    const o = await ov(); ok(/Punched OUT/.test(o.title) && /Bye bye/.test(o.details), JSON.stringify(o));
    eq((await adminRows()).map(r => r.type).sort(), ['login', 'logout']);
    const flag = await admin.evaluate(async (L) => (await supabaseClient.from('punch_records').select('early_out, early_minutes').eq('labor_id', L).eq('type', 'logout').single()).data, LABOR);
    ok(flag.early_out === true && flag.early_minutes > 200, JSON.stringify(flag)); await waitClosed();
  });
  await test('IN after the OUT the same day is accepted (second session); the day still counts from the first IN to the OUT (needs migration 016)', async () => {
    await press('#inBtn', LABOR); await waitResult('k-success');
    const o = await ov(); ok(/Punched IN/.test(o.title), JSON.stringify(o));
    const rows = await adminRows(); eq(rows.map(r => r.type).sort(), ['login', 'login', 'logout']);
    const out = await admin.evaluate(async (L) => (await supabaseClient.from('punch_records').select('time').eq('labor_id', L).eq('type', 'logout').single()).data.time, LABOR);
    const day = await admin.evaluate(async (L) => (await supabaseClient.from('daily_attendance').select('last_logout, total_hours').eq('labor_id', L).single()).data, LABOR);
    eq(day.last_logout, out); ok(Number(day.total_hours) > 0, JSON.stringify(day)); await waitClosed();
  });
  await test('an unknown ID shows a message under the ID box and starts nothing', async () => {
    await press('#inBtn', 'NOPE999');
    await page.waitForFunction(() => document.getElementById('idError').style.display === 'block');
    ok(/not found/i.test(await page.locator('#idError').innerText()));
    eq((await ov()).active, false);
  });
  await test('no script errors during all of this', async () => { eq(errors, []); });

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
