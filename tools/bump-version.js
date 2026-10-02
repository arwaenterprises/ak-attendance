// Usage:  node tools/bump-version.js 71      (or: node tools/bump-version.js   -> current + 1)
// Sets the one app version number in both places that must always match:
//   1) CACHE_VERSION in sw.js
//   2) ?v=N on every local <script src="..."> tag of every page
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '..');
const sw = fs.readFileSync(path.join(ROOT, 'sw.js'), 'utf8');
const current = Number((sw.match(/CACHE_VERSION\s*=\s*'dawam-attendance-v(\d+)'/) || [])[1]);
if (!current) { console.error('Cannot find CACHE_VERSION in sw.js'); process.exit(1); }
const next = Number(process.argv[2] || current + 1);
if (!Number.isInteger(next) || next < 1) { console.error('Bad version number'); process.exit(1); }

function pages(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    if (e.name.startsWith('.') || ['node_modules', 'tests', 'tools', 'supabase'].includes(e.name)) return [];
    const p = path.join(dir, e.name);
    return e.isDirectory() ? pages(p) : (p.endsWith('.html') ? [p] : []);
  });
}
const write = (file, text, orig) => { if (text !== orig) fs.writeFileSync(file, text); };

write(path.join(ROOT, 'sw.js'), sw.replace(/(CACHE_VERSION\s*=\s*'dawam-attendance-v)\d+(')/, `$1${next}$2`), sw);
let tagCount = 0;
for (const f of pages(ROOT)) {
  const html = fs.readFileSync(f, 'utf8');
  const out = html.replace(/(<script\s+src="(?!https?:)[^"?]+\.js)(\?v=\d+)?(")/g, (m, a, _v, c) => { tagCount++; return `${a}?v=${next}${c}`; });
  write(f, out, html);
}
console.log(`Version ${current} -> ${next}  (${tagCount} script tags updated, sw.js updated)`);
