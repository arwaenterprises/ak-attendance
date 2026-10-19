// Day rules of the reports (no half day, Friday / holidays always paid, sandwich rule, approvals, reading page by page).
// Runs with node only: report-api.js and attendance-rules.js are loaded with a fake database (no Supabase, no browser).
// Run: node tests/day-rules.test.js
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { test, eq, ok, summary } = require('./lib/runner');

const CLIENT = 'c1';
// September 2026: Fridays 4, 11, 18, 25. "Today" for the rules is the real date, so the month is in the past.
function fixtures({ sandwichFriday = 'true', sandwichNh = 'true', extraAttendance = [] } = {}) {
  const att = (date, final, extra = {}) => ({ labor_id: 'L1', department_id: 'd1', date, first_login: '07:00:00', last_logout: '16:30:00',
    total_hours: final === 'P' ? 9.5 : 4.5, auto_status: final, final_status: final, approved_by: null, client_id: CLIENT, ...extra });
  return {
    laborers: [{ labor_id: 'L1', name: 'One', iqama_number: '1', department_id: 'd1', date_of_joining: '2020-01-01', status: 'active',
                 last_working_date: null, role: 'Labor', shift_id: null, monthly_salary: 3000 }],
    daily_attendance: [
      att('2026-09-03', 'A'),                                  // Thu short -> absent; Sat 5 no punch -> Fri 4 lost (sandwich)
      att('2026-09-10', 'P'), att('2026-09-11', 'A', { last_logout: '07:00:00', total_hours: 0 }), att('2026-09-12', 'P'),   // Fri 11 one punch
      att('2026-09-14', 'P', { auto_status: 'A', total_hours: 4.5, approved_by: 'Admin' }),                                 // approved short day
      att('2026-09-17', 'P'), att('2026-09-19', 'P'),          // Fri 18 no punch, both sides present -> paid
      // Mon 21 no punch, Tue-Thu 22-24 holidays, Fri 25, Sat 26 no punch -> the whole block is lost (holiday switch)
      ...extraAttendance
    ],
    holidays: [{ date: '2026-09-22', name: 'H' }, { date: '2026-09-23', name: 'H' }, { date: '2026-09-24', name: 'H' }],
    settings: [{ key: 'sandwich_rule_friday', value: sandwichFriday }, { key: 'sandwich_rule_nh', value: sandwichNh }],
    punch_records: [], departments: [{ id: 'd1', name: 'Dept' }], shifts: [], shift_assignments: [], labor_salaries: []
  };
}

// a very small stand-in for the Supabase query builder: returns the fixture rows of the table, honours range() and date filters
function fakeClient(db, calls) {
  return {
    from(table) {
      const q = { table, gte: null, lte: null, from: 0, to: null };
      const b = {
        select() { return b; }, eq() { return b; }, in() { return b; }, or() { return b; }, order() { return b; }, limit() { return b; }, is() { return b; },
        gte(col, v) { if (col === 'date') q.gte = v; return b; },
        lte(col, v) { if (col === 'date') q.lte = v; return b; },
        range(f, t) { q.from = f; q.to = t; return b; },
        then(resolve) {
          calls.push({ table, from: q.from });
          let rows = (db[table] || []).filter(r => (!q.gte || !r.date || r.date >= q.gte) && (!q.lte || !r.date || r.date <= q.lte));
          rows = q.to === null ? rows.slice(0, 1000) : rows.slice(q.from, q.to + 1);     // the server's 1000-row cap
          resolve({ data: rows, error: null });
        }
      };
      return b;
    }
  };
}

function load(db) {
  const calls = [];
  const ctx = { console: { log() {}, warn() {}, error: console.error }, Date, Math, Number, String, Object, Array, Set, JSON, parseInt, parseFloat, Promise };
  ctx.supabaseClient = fakeClient(db, calls);
  ctx.AUTH = { getClientId: () => CLIENT, getDepartmentFilter: () => null, getSession: () => ({ name: 'Admin' }), hasRole: () => true };
  vm.createContext(ctx);
  for (const f of ['js/utils/attendance-rules.js', 'js/api/report-api.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', f), 'utf8') + `\n;globalThis.${f.includes('rules') ? 'AttendanceRules = AttendanceRules' : 'ReportAPI = ReportAPI'};`, ctx);
  }
  return { api: ctx.ReportAPI, calls };
}

(async () => {
  console.log('Day rules (reports, 3PL)');
  const daily = async db => {
    const { api } = load(db);
    const r = await api.getCompleteAttendance('2026-09-01', '2026-09-30');
    ok(r.success, r.error);
    const by = {}; r.data.forEach(x => { by[x.date] = x; });
    return by;
  };
  const billing = async db => {
    const { api } = load(db);
    const r = await api.getMonthlyBilling(2026, 9);
    ok(r.success, r.error);
    return r.data[0];
  };

  await test('a Friday with only one punch is F (paid) in the daily report, not A', async () => {
    const by = await daily(fixtures());
    eq(by['2026-09-11'].final_status, 'F', 'Fri 11 final');
    eq(by['2026-09-11'].first_login, '07:00:00', 'its punch time is still shown');
  });
  await test('a Friday without punches between two present days is F', async () => {
    eq((await daily(fixtures()))['2026-09-18'].final_status, 'F');
  });
  await test('sandwich rule ON: absent Thursday and Saturday -> Friday A', async () => {
    eq((await daily(fixtures()))['2026-09-04'].final_status, 'A');
  });
  await test('sandwich rule OFF: the same Friday stays F', async () => {
    eq((await daily(fixtures({ sandwichFriday: 'false' })))['2026-09-04'].final_status, 'F');
  });
  await test('holiday block: absent on the working days around it -> holidays and the Friday inside it are A (holiday switch)', async () => {
    const by = await daily(fixtures({ sandwichFriday: 'false' }));
    eq(['22', '23', '24', '25'].map(d => by['2026-09-' + d].final_status), ['A', 'A', 'A', 'A']);
  });
  await test('holiday switch OFF: the block stays paid (NH, NH, NH, F)', async () => {
    const by = await daily(fixtures({ sandwichNh: 'false' }));
    eq(['22', '23', '24', '25'].map(d => by['2026-09-' + d].final_status), ['NH', 'NH', 'NH', 'F']);
  });
  await test('no half day: a short working day is A; an approved short day is P', async () => {
    const by = await daily(fixtures());
    eq(by['2026-09-03'].final_status, 'A', 'short day');
    eq(by['2026-09-14'].final_status, 'P', 'approved day');
    ok(!Object.values(by).some(x => x.final_status === 'H' || x.auto_status === 'H'), 'no H anywhere');
  });
  await test('an approved Friday lost by the sandwich rule is P', async () => {
    const db = fixtures({ extraAttendance: [{ labor_id: 'L1', department_id: 'd1', date: '2026-09-04', total_hours: 0, auto_status: 'A', final_status: 'P', approved_by: 'Admin', client_id: CLIENT }] });
    eq((await daily(db))['2026-09-04'].final_status, 'P');
  });

  await test('3PL gives each day the same status as the daily report', async () => {
    const db = fixtures();
    const by = await daily(db);
    const b = await billing(db);
    const diff = [];
    for (let d = 1; d <= 30; d++) {
      const ds = '2026-09-' + String(d).padStart(2, '0');
      if (b.days[d].status !== by[ds].final_status) diff.push(`${ds}: 3PL ${b.days[d].status}, daily ${by[ds].final_status}`);
    }
    eq(diff, [], 'differences');
  });
  await test('3PL: paid days = P + F + NH, no half-day count, salary = paid days / 30 x salary', async () => {
    const b = await billing(fixtures());
    ok(!('halfDayCount' in b), 'halfDayCount is gone');
    eq(b.totalPaidDays, b.presentCount + b.fridayCount + b.holidayCount, 'paid days');
    eq(b.presentCount + b.absentCount + b.fridayCount + b.holidayCount, 30, 'every day counted once');
    eq(b.calculatedSalary, Math.round(b.totalPaidDays * 3000 / 30), 'salary');
    // P: 10, 12, 14 (approved), 17, 19; F: 11, 18; Fri 4 and the 22-25 block lost
    eq([b.presentCount, b.fridayCount, b.holidayCount], [5, 2, 0], 'P / F / NH');
  });

  await test('attendance is read page by page (more than 1000 rows are not cut)', async () => {
    const many = [];
    for (let i = 0; i < 1500; i++) many.push({ labor_id: 'X' + i, department_id: 'd1', date: '2026-09-02', total_hours: 9.5, auto_status: 'P', final_status: 'P', client_id: CLIENT });
    const db = fixtures({ extraAttendance: many });
    db.daily_attendance.sort((a, b) => (a.labor_id === 'L1') - (b.labor_id === 'L1'));     // L1's rows after the first 1000
    const { api, calls } = load(db);
    const r = await api.getMonthlyBilling(2026, 9);
    ok(calls.filter(c => c.table === 'daily_attendance').length >= 2, 'more than one page was read');
    eq(r.data[0].days[14].status, 'P', 'the approved day of L1 (row after 1000) is still found');
  });

  process.exit(summary());
})();
