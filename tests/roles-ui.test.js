// Roles and salaries against the STAGING project (needs migration 018 there):
// Roles page, a labor created with / without a typed salary (role default), changing a labor's salary from a chosen day,
// changing a role's default salary (with the labors that are on the default), and the monthly billing using the salary of each day.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, ok, summary } = require('./lib/runner');
const fs = require('fs');

const rid = Math.random().toString(36).slice(2, 7).toUpperCase();
const ROLE = 'Driver ' + rid;
const pad = n => String(n).padStart(2, '0');
const ymd = d => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());

(async () => {
  const { srv, url } = await startServer();
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined });
  const ctx = await browser.newContext({ viewport: { width: 1400, height: 900 }, serviceWorkers: 'block' });
  await curlRoutes(ctx, /jsdelivr|supabase\.co/);
  const page = await ctx.newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  page.on('dialog', d => d.accept());
  await page.goto(url + '/index.html');
  await page.fill('#clientCode', 'TEST'); await page.fill('#username', 'admin'); await page.fill('#password', 'Test@1234'); await page.click('#loginBtn');
  await page.waitForURL(/dashboard/, { timeout: 30000 });

  const today = ymd(new Date());
  const tenAgo = ymd(new Date(Date.now() - 10 * 86400000));
  const dept = await page.evaluate(async (rid) => {
    const r = await supabaseClient.from('departments').insert({ name: 'ROLES ' + rid, code: 'R' + rid, client_id: AUTH.getClientId() }).select().single();
    return r.data && r.data.id;
  }, rid);
  ok(dept, 'department for the test');
  const db = (sql) => page.evaluate(sql);
  const roleRow = () => page.evaluate(async (n) => (await supabaseClient.from('roles').select('*').eq('name', n).single()).data, ROLE);
  const laborBy = (name) => page.evaluate(async (n) => (await supabaseClient.from('laborers').select('labor_id, role_id, role, monthly_salary').eq('name', n).single()).data, name);
  const salaryNow = (L) => page.evaluate(async (L) => { const e = await SalaryAPI.applyCurrent([{ labor_id: L, monthly_salary: null }]); return e[0].current_salary; }, L);

  // ---- Roles page
  await page.goto(url + '/admin/roles.html');
  await page.waitForFunction(() => document.querySelectorAll('#roleTable tr').length >= 1 && !/Loading/.test(document.getElementById('roleTable').innerText), null, { timeout: 30000 });
  await test('the Roles page lists the roles and marks exactly one as Default', async () => {
    const txt = await page.locator('#roleTable').innerText();
    eq((txt.match(/Default/g) || []).length, 1, txt);
  });
  await test('add a role with a default salary and an overtime rate', async () => {
    await page.click('text=➕ Add Role');
    await page.fill('#roleName', ROLE); await page.fill('#roleSalary', '2500'); await page.fill('#roleOT', '20');
    await page.click('#roleModal >> text=💾 Save');
    await page.waitForFunction((n) => document.getElementById('roleTable').innerText.includes(n), ROLE, { timeout: 15000 });
    const r = await roleRow(); eq(Number(r.default_monthly_salary), 2500); eq(Number(r.ot_rate_per_hour), 20); eq(r.is_default, false);
  });
  await test('a role name is unique (capitals ignored): the page says so', async () => {
    await page.click('text=➕ Add Role');
    await page.fill('#roleName', ROLE.toUpperCase()); await page.fill('#roleSalary', '100');
    await page.click('#roleModal >> text=💾 Save');
    await page.waitForSelector('text=already exists', { timeout: 10000 });
    await page.click('#roleModal .modal-close');
  });

  // ---- Labor Master: create labors
  await page.goto(url + '/labor/master.html');
  await page.waitForFunction(() => document.querySelectorAll('#laborTable tr').length >= 1 && !/Loading/.test(document.getElementById('laborTable').innerText), null, { timeout: 40000 });
  const addLabor = async (name, salary) => {
    await page.click('text=➕ Add Labor');
    await page.fill('#laborName', name); await page.fill('#laborIqama', '8' + String(Math.floor(Math.random() * 1e9)).padStart(9, '0'));
    await page.fill('#laborDOJ', '2020-01-01'); await page.fill('#laborNationality', 'X');
    await page.selectOption('#laborDepartment', dept);
    await page.selectOption('#laborRole', { label: ROLE });
    if (salary !== null) await page.fill('#laborSalary', String(salary));
    await page.click('#laborModal >> text=💾 Save');
    await page.waitForFunction(() => !document.getElementById('laborModal').classList.contains('active'), null, { timeout: 20000 });
  };
  await test('a labor created WITHOUT a salary gets the default salary of its role (2500)', async () => {
    ok(/Default: 2,500|Default: 2500/.test(await (async () => { await page.click('text=➕ Add Labor'); await page.selectOption('#laborRole', { label: ROLE }); const ph = await page.getAttribute('#laborSalary', 'placeholder'); await page.click('#laborModal .modal-close'); return ph; })()), 'the form shows the role default');
    await addLabor('Role Test A ' + rid, null);
    const l = await laborBy('Role Test A ' + rid);
    eq(l.role, ROLE); eq(Number(l.monthly_salary), 2500); eq(await salaryNow(l.labor_id), 2500);
  });
  await test('a labor created WITH a salary keeps the typed salary (2800)', async () => {
    await addLabor('Role Test B ' + rid, 2800);
    const l = await laborBy('Role Test B ' + rid); eq(Number(l.monthly_salary), 2800); eq(await salaryNow(l.labor_id), 2800);
  });

  // ---- change one labor's salary from a chosen day
  let LA, LB;
  await test('changing the salary of a labor asks from which day; the history keeps both', async () => {
    LA = (await laborBy('Role Test A ' + rid)).labor_id; LB = (await laborBy('Role Test B ' + rid)).labor_id;
    await page.fill('#filterId', LA); await page.waitForTimeout(400);
    await page.locator('#laborTable tr', { hasText: LA }).locator('text=Edit').click();
    await page.waitForSelector('#laborModal.active');
    await page.fill('#laborSalary', '3000');
    ok(await page.locator('#salaryFromGroup').isVisible(), 'the "applies from" date must appear');
    await page.fill('#laborSalaryFrom', tenAgo);
    await page.click('#laborModal >> text=💾 Save');
    await page.waitForFunction(() => !document.getElementById('laborModal').classList.contains('active'), null, { timeout: 20000 });
    const hist = await page.evaluate(async (L) => (await SalaryAPI.getHistory(L)).data, LA);
    eq(hist.map(h => [h.from_date, Number(h.monthly_salary)]).sort().join('|'), [['2000-01-01', 2500], [tenAgo, 3000]].sort().join('|'));
    eq(await salaryNow(LA), 3000);
  });

  // ---- change the default salary of the role: from today, including the labors on the default
  await test('changing the default salary of a role: asks the day and offers the labors on the default; the personal salary stays', async () => {
    await page.goto(url + '/admin/roles.html');
    await page.waitForFunction((n) => document.getElementById('roleTable').innerText.includes(n), ROLE, { timeout: 30000 });
    await page.locator('#roleTable tr', { hasText: ROLE }).locator('text=Edit').click();
    await page.fill('#roleSalary', '2700');
    await page.click('#roleModal >> text=💾 Save');
    await page.waitForSelector('#salaryModal.active', { timeout: 10000 });
    ok(/2,500|2500/.test(await page.locator('#salarySummary').innerText()) && /2,700|2700/.test(await page.locator('#salarySummary').innerText()), await page.locator('#salarySummary').innerText());
    await page.fill('#salaryFrom', today);
    await page.click('#salaryOk');
    await page.waitForFunction(() => !document.getElementById('salaryModal').classList.contains('active'), null, { timeout: 20000 });
    eq(Number((await roleRow()).default_monthly_salary), 2700);
    eq(await salaryNow(LA), 3000);    // had a personal change (3000): not on the default any more, stays
    eq(await salaryNow(LB), 2800);    // typed at creation: stays
  });

  // ---- monthly billing: each day with the salary of that day
  await test('monthly billing: each day is paid with the salary valid on that day (3000 until the 15th, 3600 from the 16th)', async () => {
    const now = new Date(), y = now.getFullYear(), m = now.getMonth() + 1, last = new Date(y, m, 0).getDate();
    const from16 = y + '-' + pad(m) + '-16';
    const out = await page.evaluate(async (a) => {
      await new Promise((res, rej) => { const s = document.createElement('script'); s.src = '../js/api/report-api.js'; s.onload = res; s.onerror = rej; document.head.appendChild(s); });
      const set = await SalaryAPI.setSalary([a.L], 3600, a.from16);
      if (!set.success) return { err: set.error };
      // make the 15th and the 16th a present day so both salaries matter (a day that is a Friday or a holiday is paid anyway)
      const cid = AUTH.getClientId();
      const lab = (await supabaseClient.from('laborers').select('department_id').eq('labor_id', a.L).single()).data;
      const days = [a.y + '-' + a.mm + '-15', a.y + '-' + a.mm + '-16', a.y + '-' + a.mm + '-17'];
      const ins = await supabaseClient.from('daily_attendance').upsert(days.map(d => ({ labor_id: a.L, department_id: lab.department_id, date: d, first_login: '06:00', last_logout: '17:00', total_hours: 11, auto_status: 'P', final_status: 'P', client_id: cid })), { onConflict: 'labor_id,date' });
      if (ins.error) return { err: ins.error.message };
      const rep = await ReportAPI.getMonthlyBilling(a.y, a.m, null, 'active');
      const row = (rep.data || []).find(r => r.laborId === a.L);
      return { row: row && { days: Object.fromEntries(Object.entries(row.days).map(([d, v]) => [d, v.status])), calculatedSalary: row.calculatedSalary, monthlySalary: row.monthlySalary, salaryChanged: row.salaryChanged }, err: rep.error };
    }, { L: LA, from16, y, m, mm: pad(m), last });
    ok(!out.err && out.row, JSON.stringify(out));
    const part = s => (s === 'P' || s === 'F' || s === 'NH') ? 1 : (s === 'H' ? 0.5 : 0);
    let sum = 0; for (let d = 1; d <= last; d++) sum += part(out.row.days[d]) * (d >= 16 ? 3600 : 3000);
    eq(out.row.calculatedSalary, Math.round(sum / last));
    eq(out.row.monthlySalary, 3600); ok(out.row.salaryChanged === true, 'salaryChanged flag');
  });

  await test('no script errors', async () => { eq(errors, []); });
  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
