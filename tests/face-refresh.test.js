// Small photo in Labor Master + automatic face refresh from the punch terminal, against the STAGING project (needs migration 015 there).
// The face check is replaced by a stand-in (a real one needs a camera); everything else (login, saving, the database rules) is real.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const KEY = 'test-terminal-key-1234';
const rid = Math.random().toString(36).slice(2, 7).toUpperCase();
const [WEAK, STRONG, REFUSED] = ['FRW' + rid, 'FRS' + rid, 'FRX' + rid];
const JPEG_B64 = fs.readFileSync(__dirname + '/photos.test.js', 'utf8').match(/JPEG_B64 = '([^']+)'/)[1];

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined, args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'] });
  const newCtx = async (extra = {}) => { const c = await browser.newContext(Object.assign({ viewport: { width: 1280, height: 900 }, serviceWorkers: 'block' }, extra));
    await curlRoutes(c, /jsdelivr|supabase\.co/); await c.route(/justadudewhohacks/, r => r.abort()); return c; };

  const adminCtx = await newCtx(); const admin = await adminCtx.newPage();
  const errors = []; admin.on('pageerror', e => errors.push(e.message));
  await admin.goto(url + '/index.html');
  await admin.fill('#clientCode', 'TEST'); await admin.fill('#username', 'admin'); await admin.fill('#password', 'Test@1234'); await admin.click('#loginBtn');
  await admin.waitForURL(/dashboard/, { timeout: 30000 });
  const setup = await admin.evaluate(async (L) => {
    const cid = AUTH.getClientId(), r = L[0].slice(3);
    const d = await supabaseClient.from('departments').insert({ name: 'FACE ' + r, code: 'F' + r, client_id: cid }).select().single();
    const loc = await supabaseClient.from('punch_locations').insert({ name: 'Gate ' + r, department_id: d.data.id, latitude: 1, longitude: 1, client_id: cid }).select().single();
    const errs = [];
    for (const id of L) {
      const iq = '8' + String(Math.floor(Math.random() * 1e9)).padStart(9, '0');
      await supabaseClient.from('iqama_registry').insert({ iqama_number: iq, labor_id: id, client_id: cid });
      const l = await supabaseClient.from('laborers').insert({ labor_id: id, iqama_number: iq, name: 'Face ' + id, nationality: 'X', date_of_joining: '2020-01-01', department_id: d.data.id, client_id: cid, face_enrolled: true, face_descriptor: [0.1, 0.2, 0.3], needs_reenrollment: true, low_confidence_count: 2 });
      if (l.error) errs.push(l.error.message);
    }
    return { ok: !!(d.data && loc.data) && !errs.length, err: errs.join() };
  }, [WEAK, STRONG, REFUSED]);
  ok(setup.ok, 'setup: ' + JSON.stringify(setup));
  const row = (id) => admin.evaluate(async (id) => { const r = (await supabaseClient.from('laborers').select('face_thumb, face_refreshed_at, face_descriptor, needs_reenrollment, low_confidence_count').eq('labor_id', id).single()).data;
    return { thumb: r.face_thumb, refreshed: !!r.face_refreshed_at, len: r.face_descriptor.length, needs: r.needs_reenrollment, low: r.low_confidence_count }; }, id);

  // ---- terminal
  const ctx = await newCtx({ viewport: { width: 390, height: 844 }, geolocation: { latitude: 1, longitude: 1 }, permissions: ['geolocation', 'camera'] });
  const page = await ctx.newPage(); page.on('pageerror', e => errors.push(e.message));
  await page.goto(url + '/punch/index.html?client=TEST#key=' + KEY);
  await page.waitForFunction(() => document.getElementById('mainContainer').style.display === 'flex', null, { timeout: 45000 });
  await page.waitForFunction(() => window.userCoords, null, { timeout: 20000 });
  await page.waitForFunction((L) => allLaborers.some(l => l.labor_id === L), REFUSED, { timeout: 20000 });
  await page.waitForFunction(() => !document.getElementById('statusOverlay').classList.contains('active'), null, { timeout: 15000 });
  await page.evaluate((b64) => {
    modelsLoaded = true;
    window.__dist = 0.05;
    PhotoUtils.capturePhoto = async () => { const c = document.createElement('canvas'); c.width = 320; c.height = 240; c.getContext('2d').fillRect(100, 60, 120, 120);
      const bin = atob(b64), u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return { canvas: c, blob: new Blob([u], { type: 'image/jpeg' }) }; };
    window.faceapi = { TinyFaceDetectorOptions: function () {}, euclideanDistance: () => window.__dist,
      detectSingleFace: () => ({ withFaceLandmarks: () => ({ withFaceDescriptor: async () => ({ descriptor: new Float32Array(128).fill(0.5), detection: { box: { x: 100, y: 60, width: 120, height: 120 } } }) }) }) };
  }, JPEG_B64);
  const press = async (id, labor, dist) => { await page.evaluate((d) => { window.__dist = d; }, dist); await page.fill('#laborIdInput', labor); await page.click(id); };
  const waitClosed = () => page.waitForFunction(() => { const o = document.getElementById('statusOverlay'); return !o.classList.contains('active'); }, null, { timeout: 15000 });
  const waitResult = (cls) => page.waitForFunction((c) => { const o = document.getElementById('statusOverlay'); return o.classList.contains('active') && o.classList.contains(c); }, cls, { timeout: 15000 });
  const until = async (fn, ms = 10000) => { const t0 = Date.now(); for (;;) { const v = await fn(); if (v) return v; if (Date.now() - t0 > ms) return v; await new Promise(r => setTimeout(r, 400)); } };

  console.log('Terminal');
  await test('a strong match: punch accepted, the labor gets a small photo, the saved face is left untouched', async () => {
    await press('#inBtn', STRONG, 0.05); await waitResult('k-success');
    const r = await until(async () => { const x = await row(STRONG); return x.thumb ? x : null; });
    ok(r && /^data:image\/jpeg;base64,/.test(r.thumb) && r.thumb.length < 20000, JSON.stringify(r && { len: r.thumb && r.thumb.length }));
    eq(r.len, 3); eq(r.refreshed, false); await waitClosed();
  });
  await test('a weaker but accepted match (80%): punch accepted, saved face + photo replaced, re-enrol flag and counter cleared', async () => {
    await press('#inBtn', WEAK, 0.2); await waitResult('k-success');
    const r = await until(async () => { const x = await row(WEAK); return x.refreshed ? x : null; });
    ok(r, 'face was not refreshed'); eq(r.len, 128); ok(r.thumb, 'no photo'); eq(r.needs, false); eq(r.low, 0); await waitClosed();
  });
  await test('a refused match (40%): nothing is replaced and no photo is stored', async () => {
    await press('#inBtn', REFUSED, 0.6);
    await page.waitForFunction(() => document.getElementById('statusOverlay').classList.contains('k-error'), null, { timeout: 15000 });
    await new Promise(r => setTimeout(r, 2000));
    const r = await row(REFUSED); eq(r.len, 3); eq(r.thumb, null); eq(r.refreshed, false);
  });

  console.log('\nLabor Master');
  await test('Labor Master shows the small photo for labors that have one, and a placeholder for the others', async () => {
    await admin.goto(url + '/labor/master.html');
    await admin.waitForFunction((L) => document.getElementById('laborTable').innerText.includes(L), STRONG, { timeout: 30000 });
    const tr = (id) => admin.locator('#laborTable tr', { hasText: id });
    await admin.waitForFunction((id) => { const t = Array.from(document.querySelectorAll('#laborTable tr')).find(r => r.innerText.includes(id)); return t && t.querySelector('img.labor-thumb'); }, STRONG, { timeout: 15000 });
    eq(await tr(STRONG).locator('img.labor-thumb').count(), 1);
    eq(await tr(WEAK).locator('img.labor-thumb').count(), 1);
    eq(await tr(REFUSED).locator('img.labor-thumb').count(), 0);
    eq(await tr(REFUSED).locator('.labor-thumb-empty').count(), 1);
    const w = await tr(STRONG).locator('img.labor-thumb').evaluate(i => i.naturalWidth);
    ok(w > 0, 'photo did not load');
  });
  await test('no script errors', async () => { eq(errors, []); });

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
