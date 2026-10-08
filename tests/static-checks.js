// Static checks (no browser, no network). Run:  node tests/static-checks.js
// In CI, BASE_SHA is set so the "version bumped" rule can compare with the previous commit.
const fs = require('fs'), path = require('path'), { execSync } = require('child_process');
const ROOT = path.resolve(__dirname, '..');
let failed = 0;
const check = (name, cond, detail) => { console.log(`${cond ? '  PASS' : '  FAIL'}  ${name}${!cond && detail ? '\n        ' + detail : ''}`); if (!cond) failed++; };

const SKIP = new Set(['.git', 'node_modules', 'tests', 'tools', 'supabase', 'templates', 'icons', 'js', 'css']);
const pages = [];
(function walk(dir) { for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
  if (e.name.startsWith('.') || SKIP.has(e.name) && dir === ROOT) continue;
  const p = path.join(dir, e.name);
  if (e.isDirectory()) { if (!SKIP.has(e.name)) walk(p); } else if (p.endsWith('.html')) pages.push(p);
} })(ROOT);

const sw = fs.readFileSync(path.join(ROOT, 'sw.js'), 'utf8');
const swVersion = Number((sw.match(/CACHE_VERSION\s*=\s*'dawam-attendance-v(\d+)'/) || [])[1]);
check('sw.js has the line  const CACHE_VERSION = \'dawam-attendance-vN\';  (the in-app check reads it)', swVersion > 0);

const tags = [];   // { page, src, v }
for (const p of pages) {
  const html = fs.readFileSync(p, 'utf8');
  for (const m of html.matchAll(/<script\s+src="(?!https?:)([^"?]+)(\?v=(\d+))?"/g))
    tags.push({ page: path.relative(ROOT, p), src: m[1], v: m[3] ? Number(m[3]) : null, abs: path.resolve(path.dirname(p), m[1]) });
}
check(`found ${pages.length} pages and ${tags.length} local script tags`, pages.length >= 10 && tags.length >= 50);
const noVersion = tags.filter(t => t.v === null);
check('every local script tag has ?v=N', noVersion.length === 0, noVersion.slice(0, 5).map(t => `${t.page}: ${t.src}`).join('\n        '));
const versions = [...new Set(tags.map(t => t.v))];
check('all script tags use the same ?v= number', versions.length === 1, 'found: ' + versions.join(', '));
check('sw.js CACHE_VERSION number equals the ?v= number (run: node tools/bump-version.js N)', versions.length === 1 && versions[0] === swVersion, `sw=${swVersion} tags=${versions.join(',')}`);
const missing = tags.filter(t => !fs.existsSync(t.abs));
check('every script file exists', missing.length === 0, missing.slice(0, 5).map(t => `${t.page}: ${t.src}`).join('\n        '));
const noUpdate = pages.filter(p => !/js\/ui\/app-update\.js\?v=\d+/.test(fs.readFileSync(p, 'utf8'))).map(p => path.relative(ROOT, p));
check('every page loads js/ui/app-update.js', noUpdate.length === 0, noUpdate.join(', '));

// service worker pre-cache list
const shellBlock = (sw.match(/const APP_SHELL = \[([\s\S]*?)\];/) || [])[1] || '';
const shell = [...shellBlock.matchAll(/'(\/[^']*)'/g)].map(m => m[1]);
check('APP_SHELL parsed', shell.length > 20);
const shellMissing = shell.filter(u => u !== '/' && !fs.existsSync(path.join(ROOT, u.slice(1))));
check('every file listed in APP_SHELL exists', shellMissing.length === 0, shellMissing.join(', '));
const needed = [...new Set(tags.map(t => '/' + path.relative(ROOT, t.abs).split(path.sep).join('/')))];
const notCached = needed.filter(u => !shell.includes(u));
check('every script a page loads is in APP_SHELL (otherwise it is missing offline)', notCached.length === 0, notCached.join(', '));
const pagesNotCached = pages.map(p => '/' + path.relative(ROOT, p).split(path.sep).join('/')).filter(u => !shell.includes(u));
check('every page is in APP_SHELL', pagesNotCached.length === 0, pagesNotCached.join(', '));

// published site: only app files go online (ROADMAP.md, supabase/, tests/ ... must NOT be public)
const siteTools = require('../tools/build-site.js');
const siteOut = fs.mkdtempSync(path.join(require('os').tmpdir(), 'site-'));
siteTools.build(siteOut);
const unclassified = siteTools.unclassified();
check('every top-level file/folder is classified public or private in tools/build-site.js', unclassified.length === 0, 'add to the right list: ' + unclassified.join(', '));
const leaked = ['ROADMAP.md', 'README.md', 'supabase', 'tests', 'tools', '.github', '.git', 'node_modules'].filter(n => fs.existsSync(path.join(siteOut, n)));
check('built site does not contain private files (ROADMAP, supabase, tests, tools ...)', leaked.length === 0, leaked.join(', '));
const notInSite = [...new Set([...shell.filter(u => u !== '/'), ...needed])].filter(u => !fs.existsSync(path.join(siteOut, u.slice(1))));
check('built site contains every page, script, icon and file the app needs offline', notInSite.length === 0, notInSite.slice(0, 6).join(', '));
check('built site contains sw.js, manifest.json, index.html', ['sw.js', 'manifest.json', 'index.html'].every(f => fs.existsSync(path.join(siteOut, f))));
fs.rmSync(siteOut, { recursive: true, force: true });

// manifest
const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, 'manifest.json'), 'utf8'));
check('manifest has name, short_name, start_url, display standalone', !!(manifest.name && manifest.short_name && manifest.start_url && manifest.display === 'standalone'));
const sizes = (manifest.icons || []).map(i => i.sizes);
check('manifest has PNG icons 192x192 and 512x512', sizes.includes('192x192') && sizes.includes('512x512') && manifest.icons.every(i => i.type === 'image/png'));
const iconsMissing = (manifest.icons || []).filter(i => !fs.existsSync(path.join(ROOT, i.src.slice(1))));
check('every manifest icon file exists', iconsMissing.length === 0, iconsMissing.map(i => i.src).join(', '));

// the old "AK" name must not come back in visible text (internal storage names are allowed on purpose)
const ALLOW = /ak_attendance_session|AKAttendanceDB/;
const textFiles = [];
(function walk(dir) { for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
  if (e.name.startsWith('.') || ['node_modules', 'tests', 'tools', 'supabase', 'icons'].includes(e.name)) continue;
  const p = path.join(dir, e.name);
  if (e.isDirectory()) walk(p); else if (/\.(html|js|css|json|md)$/.test(e.name) && e.name !== 'ROADMAP.md') textFiles.push(p);
} })(ROOT);
const akHits = [];
for (const f of textFiles) fs.readFileSync(f, 'utf8').split(/\r?\n/).forEach((line, i) => {
  if (/\bAK\b|AK_|Al Abdul Karim|\bHADIR\b/i.test(line) && !ALLOW.test(line)) akHits.push(`${path.relative(ROOT, f)}:${i + 1}: ${line.trim().slice(0, 70)}`);
});
check('no leftover "AK" / "Al Abdul Karim" / "HADIR" names in app files', akHits.length === 0, akHits.slice(0, 6).join('\n        '));

// new login: the email domain must be the same in the app and in the database migration; the staging bundle must be current
const supaJs = fs.readFileSync(path.join(ROOT, 'js/config/supabase.js'), 'utf8');
const mig002 = fs.readFileSync(path.join(ROOT, 'supabase/migrations/002_auth_login.sql'), 'utf8');
const domainJs = (supaJs.match(/DAWAM_LOGIN_EMAIL_DOMAIN\s*=\s*'([^']+)'/) || [])[1];
check('login email domain is the same in js/config/supabase.js and migration 002', !!domainJs && mig002.includes('.' + domainJs), String(domainJs));
const bundleFile = path.join(ROOT, 'supabase/staging-security-bundle.sql');
check('supabase/staging-security-bundle.sql is up to date (run: node tools/build-staging-bundle.js)',
  fs.existsSync(bundleFile) && fs.readFileSync(bundleFile, 'utf8') === require('../tools/build-staging-bundle.js').bundle());
const termFile = path.join(ROOT, 'supabase/staging-terminal-bundle.sql');
check('supabase/staging-terminal-bundle.sql is up to date (run: node tools/build-staging-bundle.js)',
  fs.existsSync(termFile) && fs.readFileSync(termFile, 'utf8') === require('../tools/build-staging-bundle.js').terminalBundle());
// the login-mode switch must exist ONLY in js/config/supabase.js and say 'supabase' (a page with its own copy that said 'legacy' broke self-enrollment on the live site)
const modeCopies = [];
(function scan(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (['node_modules', '.git', 'tests', 'supabase', '_site', 'tools'].includes(e.name)) continue;
    const f = path.join(dir, e.name);
    if (e.isDirectory()) scan(f);
    else if (/\.(html|js)$/.test(e.name) && /DAWAM_AUTH_MODE/.test(fs.readFileSync(f, 'utf8'))) modeCopies.push(path.relative(ROOT, f));
  }
})(ROOT);
check("no page or script mentions DAWAM_AUTH_MODE (the old login mode switch is gone; a page with its own copy once broke self-enrollment on the live site)", modeCopies.length === 0, modeCopies.join(', '));
check('the old login is gone: no file mentions DAWAM_AUTH_MODE any more', !/DAWAM_AUTH_MODE/.test(supaJs));

// version must be bumped when app files changed (CI sets BASE_SHA)
const base = process.env.BASE_SHA;
if (base && !/^0+$/.test(base)) {
  try {
    const changed = execSync(`git diff --name-only ${base} HEAD`, { cwd: ROOT }).toString().split('\n')
      .filter(f => f && f !== 'sw.js' && /^(.*\.html|js\/.*|css\/.*|icons\/.*|manifest\.json)$/.test(f));
    const baseSw = execSync(`git show ${base}:sw.js`, { cwd: ROOT }).toString();
    const baseVersion = (baseSw.match(/CACHE_VERSION\s*=\s*'([^']+)'/) || [])[1];
    const nowVersion = (sw.match(/CACHE_VERSION\s*=\s*'([^']+)'/) || [])[1];
    check('version bumped when app files changed', changed.length === 0 || baseVersion !== nowVersion,
      `${changed.length} app file(s) changed (e.g. ${changed[0]}) but CACHE_VERSION is still ${nowVersion}. Run: node tools/bump-version.js`);
  } catch (e) { console.log('  NOTE  could not compare with ' + base + ' (' + String(e.message).split('\n')[0] + ')'); }
} else {
  console.log('  NOTE  BASE_SHA not set - skipping the "version bumped" check');
}

console.log(failed ? `\n${failed} check(s) FAILED` : '\nAll static checks passed');
process.exit(failed ? 1 : 0);
