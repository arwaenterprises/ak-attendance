// End-to-end tests of PRIVATE PHOTOS and SAFE SELF-ENROLLMENT against the STAGING Supabase project (ROADMAP S4).
// Needs staging with migrations 001-006 applied (006 = supabase/migrations/006_private_photos.sql) and the terminal set up (S3).
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const KEY = 'test-terminal-key-1234';
const rid = Math.random().toString(36).slice(2, 7).toUpperCase();
const LABOR = 'PHO' + rid;
const JPEG_B64 = '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=';

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined });
  const newCtx = async () => { const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, serviceWorkers: 'block' });
    await curlRoutes(ctx, /jsdelivr|supabase\.co/); await ctx.route(/justadudewhohacks/, r => r.abort()); return ctx; };

  // admin
  const adminCtx = await newCtx(); const admin = await adminCtx.newPage(); await admin.goto(url + '/tests/harness.html');
  await admin.waitForFunction(() => typeof AUTH !== 'undefined' && typeof PhotoURL !== 'undefined' && typeof EnrollmentAPI !== 'undefined');
  const al = await admin.evaluate(() => AUTH.login('TEST', 'admin', 'Test@1234'));
  if (!al.success) { console.error('admin login failed - staging not set up? ' + JSON.stringify(al)); process.exit(2); }
  const clientId = await admin.evaluate(() => AUTH.getClientId());
  const setup = await admin.evaluate(async (LABOR) => {
    const cid = AUTH.getClientId(), r = LABOR.slice(3);
    const d = await supabaseClient.from('departments').insert({ name: 'PHO ' + r, code: 'P' + r, client_id: cid }).select().single();
    const iq = '6' + String(Math.floor(Math.random() * 1e9)).padStart(9, '0');
    await supabaseClient.from('iqama_registry').insert({ iqama_number: iq, labor_id: LABOR, client_id: cid });
    const l = await supabaseClient.from('laborers').insert({ labor_id: LABOR, iqama_number: iq, name: 'Photo Test', nationality: 'X', date_of_joining: '2020-01-01', department_id: d.data.id, client_id: cid, face_enrolled: true, face_descriptor: [0.1, 0.2] });
    return { dept: d.data && d.data.id, labor: !l.error, err: (d.error || l.error || {}).message };
  }, LABOR);
  ok(setup.dept && setup.labor, 'test data setup failed: ' + JSON.stringify(setup));

  // terminal (the punch page signs in with the terminal key)
  const termCtx = await newCtx(); const term = await termCtx.newPage();
  await term.goto(url + '/punch/index.html?client=TEST#key=' + KEY);
  await term.waitForFunction(() => document.getElementById('mainContainer').style.display === 'flex', null, { timeout: 45000 });

  // anonymous visitor
  const anonCtx = await newCtx(); const anon = await anonCtx.newPage(); await anon.goto(url + '/tests/harness.html');
  await anon.waitForFunction(() => typeof SUPABASE_URL !== 'undefined');
  const anonClient = `supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } })`;

  const myPath = `${clientId}/punches/${LABOR}_test.jpg`;
  const jpeg = (page, path, client = 'supabaseClient') => page.evaluate(async ([b64, path, client]) => {
    const bin = atob(b64), bytes = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const c = client === 'supabaseClient' ? supabaseClient : eval(client);
    const r = await c.storage.from('punch-photos').upload(path, new Blob([bytes], { type: 'image/jpeg' }), { contentType: 'image/jpeg', upsert: false });
    return { error: r.error ? r.error.message : null };
  }, [JPEG_B64, path, client]);
  const fetchOk = (page, u) => page.evaluate(async (u) => { const r = await fetch(u); return { status: r.status, type: r.headers.get('content-type') }; }, u);

  console.log('Punch photos');
  await test('a terminal can add a photo to its own company folder', async () => { eq((await jpeg(term, myPath)).error, null); });
  await test('a terminal cannot add a photo outside its company folder, or a non-JPEG file', async () => {
    const a = await jpeg(term, `punches/${LABOR}_root.jpg`);
    const b = await jpeg(term, `00000000-0000-0000-0000-00000000dead/punches/${LABOR}_x.jpg`);
    const c = await term.evaluate(async (p) => { const r = await supabaseClient.storage.from('punch-photos').upload(p, new Blob(['hello'], { type: 'text/plain' }), { contentType: 'text/plain' }); return r.error ? r.error.message : null; }, `${clientId}/punches/${LABOR}_text.txt`);
    ok(a.error && b.error && c, JSON.stringify([a, b, c]));
  });
  await test('the photo link is no longer public: the old public web address does not show the photo', async () => {
    const r = await fetchOk(anon, await anon.evaluate((p) => `${SUPABASE_URL}/storage/v1/object/public/punch-photos/${p}`, myPath));
    ok(r.status !== 200, 'public address answered ' + r.status);
  });
  await test('staff of the company get a short-lived signed link that shows the photo', async () => {
    const link = await admin.evaluate((p) => PhotoURL.resolve(p), myPath);
    ok(link && link.includes('token='), 'signed link: ' + link);
    const r = await fetchOk(admin, link); eq(r.status, 200); ok((r.type || '').includes('image/jpeg'), r.type);
  });
  await test('the terminal of the company can show its own photo too (my punches list)', async () => {
    const link = await term.evaluate((p) => PhotoURL.resolve(p), myPath); ok(link, 'terminal got no link');
    eq((await fetchOk(term, link)).status, 200);
  });
  await test('an old-style stored web address is turned into the same file path', async () => {
    const p = await admin.evaluate(() => PhotoURL.pathOf('https://abc.supabase.co/storage/v1/object/public/punch-photos/punches/L1_12.jpg?x=1'));
    eq(p, 'punches/L1_12.jpg');
  });
  await test('without a login: no signed link, no listing, no upload, no delete', async () => {
    const r = await anon.evaluate(async ([path, root]) => {
      const c = eval(root); const s = c.storage.from('punch-photos');
      const sign = await s.createSignedUrl(path, 60);
      const list = await s.list(path.split('/')[0] + '/punches');
      const up = await s.upload(path.replace('_test', '_anon'), new Blob(['x'], { type: 'image/jpeg' }), { contentType: 'image/jpeg' });
      const del = await s.remove([path]);
      return { sign: !!sign.error, listed: (list.data || []).length, up: !!up.error, delRemoved: (del.data || []).length };
    }, [myPath, anonClient]);
    eq(r, { sign: true, listed: 0, up: true, delRemoved: 0 });
  });
  await test('a punch can point at the photo; the terminal refuses a path inside another company folder', async () => {
    const good = await term.evaluate(async ([L, p]) => TerminalAPI.recordPunch({ laborId: L, type: 'login', date: DateUtils.today(), time: '09:00:00', photoUrl: p }), [LABOR, myPath]);
    const bad = await term.evaluate(async (L) => TerminalAPI.recordPunch({ laborId: L, type: 'logout', date: DateUtils.today(), time: '10:00:00', photoUrl: '00000000-0000-0000-0000-00000000dead/punches/x.jpg' }), LABOR);
    ok(good.success, JSON.stringify(good)); ok(!bad.success && /invalid photo path/.test(bad.error), JSON.stringify(bad));
    const stored = await admin.evaluate(async (L) => (await supabaseClient.from('punch_records').select('photo_url').eq('labor_id', L)).data.map(r => r.photo_url), LABOR);
    eq(stored, [myPath], 'stored value is the path');
  });

  console.log('\nSelf-enrollment');
  let link = null;
  await test('the strong token generator gives 32 letters/digits and never repeats', async () => {
    const t = await admin.evaluate(() => { const s = new Set(); for (let i = 0; i < 2000; i++) s.add(EnrollmentAPI.generateToken()); return { n: s.size, ok: [...s].every(x => /^[A-Za-z0-9]{32}$/.test(x)) }; });
    eq(t, { n: 2000, ok: true });
  });
  await test('an administrator creates a link; the labor opens it and sees their own name (no table access needed)', async () => {
    link = await admin.evaluate(async (L) => EnrollmentAPI.createLink(L), LABOR);
    ok(link.success, JSON.stringify(link));
    const c = await newCtx(); const page = await c.newPage();
    await page.goto(url + '/labor/enroll-self.html?token=' + link.data.token);
    await page.waitForFunction(() => typeof tokenData !== 'undefined' && tokenData !== null, null, { timeout: 30000 });
    eq(await page.evaluate(() => tokenData.laborName), 'Photo Test');
    await c.close();
  });
  await test('a made-up link is shown as invalid', async () => {
    const c = await newCtx(); const page = await c.newPage();
    await page.goto(url + '/labor/enroll-self.html?token=' + 'x'.repeat(32));
    await page.waitForFunction(() => !document.getElementById('errorState').classList.contains('hidden'), null, { timeout: 30000 });
    ok((await page.locator('#errorMessage').innerText()).includes('Invalid link'));
    await c.close();
  });
  const enrollPath = () => `${clientId}/enrollment/${link.data.token}.jpg`;
  await test('the labor can upload ONE photo for their link and submit; nothing else is allowed', async () => {
    const wrongPath = await jpeg(anon, `${clientId}/enrollment/${'y'.repeat(32)}.jpg`, anonClient);
    const wrongFolder = await jpeg(anon, `${clientId}/punches/${LABOR}_evil.jpg`, anonClient);
    ok(wrongPath.error && wrongFolder.error, 'wrong paths must be refused: ' + JSON.stringify([wrongPath, wrongFolder]));
    const noPhotoYet = await anon.evaluate(async ([t, p, root]) => { const c = eval(root); const r = await c.rpc('enrollment_submit', { p_token: t, p_descriptor: JSON.stringify(Array(128).fill(0.5)), p_photo_path: p }); return r.error ? r.error.message : 'accepted'; }, [link.data.token, enrollPath(), anonClient]);
    ok(/not uploaded/i.test(noPhotoYet), 'submit before the photo exists: ' + noPhotoYet);
    eq((await jpeg(anon, enrollPath(), anonClient)).error, null, 'upload of the own photo');
    const sub = await anon.evaluate(async ([t, p, root]) => { const c = eval(root); const r = await c.rpc('enrollment_submit', { p_token: t, p_descriptor: JSON.stringify(Array(128).fill(0.5)), p_photo_path: p }); return r.error ? r.error.message : r.data; }, [link.data.token, enrollPath(), anonClient]);
    ok(sub && sub.success, JSON.stringify(sub));
    const again = await anon.evaluate(async ([t, p, root]) => { const c = eval(root); const r = await c.rpc('enrollment_submit', { p_token: t, p_descriptor: JSON.stringify(Array(128).fill(0.5)), p_photo_path: p }); return r.error ? r.error.message : 'accepted'; }, [link.data.token, enrollPath(), anonClient]);
    ok(/already been used/i.test(again), 'second submit: ' + again);
    const afterUse = await jpeg(anon, enrollPath().replace('.jpg', '2.jpg'), anonClient);
    ok(afterUse.error, 'upload after use must be refused');
  });
  await test('the administrator sees the submission with a working signed photo link, approves it, and the photo is removed', async () => {
    const pending = await admin.evaluate(async () => (await EnrollmentAPI.getPendingEnrollments()).data.map(x => ({ id: x.id, labor_id: x.labor_id, photo_url: x.photo_url })));
    const mine = pending.find(x => x.labor_id === LABOR); ok(mine, 'pending list has it');
    eq(mine.photo_url, enrollPath(), 'stored path');
    const shown = await admin.evaluate((p) => PhotoURL.resolve(p), mine.photo_url); ok(shown, 'signed link'); eq((await fetchOk(admin, shown)).status, 200);
    const ap = await admin.evaluate(async (id) => EnrollmentAPI.approveEnrollment(id), mine.id); ok(ap.success, JSON.stringify(ap));
    const gone = await admin.evaluate(async (p) => { const r = await supabaseClient.storage.from('punch-photos').createSignedUrl(p, 60); return r.error ? 'gone' : 'still there'; }, mine.photo_url);
    eq(gone, 'gone', 'photo after approval');
    const enrolled = await admin.evaluate(async (L) => (await supabaseClient.from('laborers').select('face_enrolled,face_descriptor').eq('labor_id', L).single()).data, LABOR);
    ok(enrolled.face_enrolled && Array.isArray(enrolled.face_descriptor) && enrolled.face_descriptor.length === 128, 'face data stored');
  });
  await test('an expired link is refused everywhere (page message, photo upload)', async () => {
    const l2 = await admin.evaluate(async (L) => EnrollmentAPI.createLink(L), LABOR); ok(l2.success);
    await admin.evaluate(async (t) => { await supabaseClient.from('enrollment_links').update({ expires_at: new Date(Date.now() - 60000).toISOString() }).eq('token', t); }, l2.data.token);
    const c = await newCtx(); const page = await c.newPage();
    await page.goto(url + '/labor/enroll-self.html?token=' + l2.data.token);
    await page.waitForFunction(() => !document.getElementById('errorState').classList.contains('hidden'), null, { timeout: 30000 });
    ok((await page.locator('#errorMessage').innerText()).includes('expired'));
    await c.close();
    ok((await jpeg(anon, `${clientId}/enrollment/${l2.data.token}.jpg`, anonClient)).error, 'upload for an expired link must be refused');
  });

  // ---- cleanup
  await admin.evaluate(async ([L, dept, cid]) => {
    const s = supabaseClient.storage.from('punch-photos');
    const names = [`${cid}/punches/${L}_test.jpg`]; await s.remove(names);
    const links = (await supabaseClient.from('enrollment_links').select('token').eq('labor_id', L)).data || [];
    await s.remove(links.map(l => `${cid}/enrollment/${l.token}.jpg`));
    await supabaseClient.from('enrollment_links').delete().eq('labor_id', L);
    await supabaseClient.from('punch_records').delete().eq('labor_id', L);
    await supabaseClient.from('daily_attendance').delete().eq('labor_id', L);
    await supabaseClient.from('laborers').delete().eq('labor_id', L);
    await supabaseClient.from('iqama_registry').delete().eq('labor_id', L);
    await supabaseClient.from('departments').delete().eq('id', dept);
  }, [LABOR, setup.dept, clientId]);

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
