// Tiny test runner: no framework needed.
const results = [];
async function test(name, fn, opts = {}) {
  try { await fn(); results.push({ name, ok: true, known: opts.knownIssue }); console.log(`  PASS  ${name}${opts.knownIssue ? '   [documents known issue: ' + opts.knownIssue + ']' : ''}`); }
  catch (e) { results.push({ name, ok: false, err: e.message }); console.log(`  FAIL  ${name}\n        ${e.message}`); }
}
function eq(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${what || 'value'}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function ok(cond, what) { if (!cond) throw new Error(what || 'expected true'); }
function summary() {
  const failed = results.filter(r => !r.ok);
  console.log(`\n${results.length - failed.length} passed, ${failed.length} failed`);
  return failed.length === 0 ? 0 : 1;
}
module.exports = { test, eq, ok, summary };
