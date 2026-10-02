// Which database and which login does each web address use? (No database calls are made.)
// Guarantees: the live address can never reach staging, and the live site keeps the old login until the planned cutover.
const { chromium } = require('playwright');
const startServer = require('./lib/server');
const curlRoutes = require('./lib/net');
const { test, eq, summary } = require('./lib/runner');
const fs = require('fs');
const LIVE = 'kyktwzwiraipwyglkhva', STAGING = 'jbfdaeyqsszoacrijldk';

(async () => {
  const { srv, url } = await startServer(); const port = new URL(url).port;
  const exe = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
  const hosts = ['dawam.arwaenterprises.com', 'dawam.arwaenterprises.com.evil.test', 'staging.example.test', 'other.example.test'];
  const browser = await chromium.launch({ executablePath: fs.existsSync(exe) ? exe : undefined,
    args: ['--host-resolver-rules=' + hosts.map(h => `MAP ${h} 127.0.0.1`).join(',')] });
  const check = async (host) => {
    const ctx = await browser.newContext({ serviceWorkers: 'block' });
    await curlRoutes(ctx, /jsdelivr/);
    let dbCalls = 0; await ctx.route(/supabase\.co/, r => { dbCalls++; r.abort(); });
    const page = await ctx.newPage();
    await page.goto(`http://${host}:${port}/tests/harness.html`);
    await page.waitForFunction(() => typeof SUPABASE_URL !== 'undefined');
    const r = await page.evaluate(() => ({ db: SUPABASE_URL.replace('https://', '').split('.')[0], mode: DAWAM_AUTH_MODE }));
    await ctx.close(); return { ...r, dbCalls };
  };
  await test('dawam.arwaenterprises.com -> LIVE database, new login', async () => eq(await check('dawam.arwaenterprises.com'), { db: LIVE, mode: 'supabase', dbCalls: 0 }));
  await test('a look-alike address (dawam.arwaenterprises.com.evil.test) -> LIVE database, new login (never staging)', async () => eq(await check('dawam.arwaenterprises.com.evil.test'), { db: LIVE, mode: 'supabase', dbCalls: 0 }));
  await test('any other address -> LIVE database, new login', async () => eq(await check('other.example.test'), { db: LIVE, mode: 'supabase', dbCalls: 0 }));
  await test('staging.* address -> staging database, new login', async () => eq(await check('staging.example.test'), { db: STAGING, mode: 'supabase', dbCalls: 0 }));
  await test('localhost -> staging database, new login', async () => eq(await check('localhost'), { db: STAGING, mode: 'supabase', dbCalls: 0 }));

  await browser.close(); srv.close();
  process.exit(summary());
})().catch(e => { console.error(e); process.exit(1); });
