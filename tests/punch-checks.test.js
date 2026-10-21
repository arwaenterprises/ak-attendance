// GPS judgement and blink detection of the punch terminal (js/utils/geo-check.js, js/utils/liveness.js). Node only, no browser.
// Run: node tests/punch-checks.test.js
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { test, eq, ok, summary } = require('./lib/runner');

const ctx = { Math, Date, Set, String, parseFloat, isFinite, Promise, setTimeout };
vm.createContext(ctx);
for (const f of ['js/utils/geo-check.js', 'js/utils/liveness.js']) {
  const name = f.includes('geo') ? 'GeoCheck' : 'Liveness';
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', f), 'utf8') + `\n;globalThis.${name} = ${name};`, ctx);
}
const { GeoCheck, Liveness } = ctx;
const R = (lat, lng, acc) => ({ lat, lng, acc });

(async () => {
  console.log('Punch checks (GPS, blink)');
  await test('no readings -> Location not found', () => eq(GeoCheck.judge([], {}).message, 'Location not found'));
  await test('0 m accuracy (fake GPS) -> Location not found', () => eq(GeoCheck.judge([R(24.7, 46.7, 0)], {}).code, 'LOCATION_NOT_FOUND'));
  await test('three identical GPS readings -> Location not found', () =>
    eq(GeoCheck.judge([R(24.7001, 46.7001, 8), R(24.7001, 46.7001, 8), R(24.7001, 46.7001, 8)], {}).code, 'LOCATION_NOT_FOUND'));
  await test('three identical Wi-Fi readings (35 m) are fine', () =>
    ok(GeoCheck.judge([R(24.7002, 46.7002, 35), R(24.7002, 46.7002, 35), R(24.7002, 46.7002, 35)], {}).ok));
  await test('gps_static_check = false allows identical readings', () =>
    ok(GeoCheck.judge([R(24.7001, 46.7001, 8), R(24.7001, 46.7001, 8), R(24.7001, 46.7001, 8)], { gps_static_check: 'false' }).ok));
  await test('weak signal (best 150 m) -> Weak GPS signal; max_gps_accuracy 200 allows it', () => {
    eq(GeoCheck.judge([R(24.7, 46.7, 150), R(24.70001, 46.7, 160)], {}).code, 'POOR_GPS');
    ok(GeoCheck.judge([R(24.7, 46.7, 150)], { max_gps_accuracy: '200' }).ok);
  });
  await test('real-looking readings pass and the best (most accurate) one is used', () => {
    const r = GeoCheck.judge([R(24.70031, 46.70012, 12), R(24.70033, 46.7001, 9), R(24.7003, 46.70014, 11)], {});
    ok(r.ok); eq(r.best.acc, 9);
  });

  // eyes: open about 0.30, closed about 0.12 (eye aspect ratio)
  const eye = (h) => [{ x: 0, y: 0 }, { x: 1, y: -h }, { x: 2, y: -h }, { x: 3, y: 0 }, { x: 2, y: h }, { x: 1, y: h }];
  await test('eye aspect ratio: open eye about 0.3, closed about 0.1', () => {
    ok(Math.abs(Liveness.ear(eye(0.45)) - 0.3) < 0.01, 'open');
    ok(Liveness.ear(eye(0.15)) < 0.12, 'closed');
  });
  const run = values => { const d = Liveness.blinkDetector(); return values.some(v => d.push(v)); };
  await test('a blink (open, closed, open) is seen', () => ok(run([0.30, 0.31, 0.29, 0.12, 0.30])));
  await test('a slow blink seen over several frames is seen', () => ok(run([0.30, 0.29, 0.31, 0.18, 0.10, 0.20, 0.29])));
  await test('a half blink of narrow eyes (open 0.20, down to 0.14) is seen (no fixed number any more)', () => ok(run([0.20, 0.21, 0.20, 0.14, 0.20])));
  await test('a printed photo (eyes never move) is not a blink', () => ok(!run([0.30, 0.30, 0.31, 0.30, 0.30, 0.29, 0.30, 0.30])));
  await test('normal jitter of open eyes (about 10 %) is not a blink', () => ok(!run([0.30, 0.28, 0.31, 0.29, 0.30, 0.28, 0.31, 0.29])));
  await test('closing the eyes without opening them again is not a blink', () => ok(!run([0.30, 0.31, 0.30, 0.12, 0.10, 0.11])));
  await test('one odd high frame does not make normal eyes look closed', () => ok(!run([0.30, 0.45, 0.30, 0.29, 0.31, 0.30])));

  const turnRun = values => { const d = Liveness.turnDetector(); return values.some(v => d.push(v)); };
  await test('a small head turn and back is seen', () => ok(turnRun([0.01, 0.00, 0.02, 0.08, 0.16, 0.10, 0.03])));
  await test('turning without coming back is not enough (the photo must face the camera)', () => ok(!turnRun([0.0, 0.01, 0.0, 0.10, 0.17, 0.18])));
  await test('a photo (nose stays between the eyes, small jitter) is not a head turn', () => ok(!turnRun([0.01, 0.0, 0.02, 0.03, -0.02, 0.04, 0.01, -0.03])));
  const pts = (noseX) => { const p = []; for (let i = 0; i < 68; i++) p.push({ x: 50, y: 50 }); p[36] = { x: 30, y: 40 }; p[45] = { x: 70, y: 40 }; p[30] = { x: noseX, y: 60 }; return p; };
  await test('nose offset: 0 looking straight, positive when the nose moves right', () => {
    ok(Math.abs(Liveness.noseOffset(pts(50))) < 1e-9); ok(Liveness.noseOffset(pts(58)) > 0.15);
  });

  process.exit(summary());
})();
