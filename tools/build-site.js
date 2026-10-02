// Builds the folder that is published on the website (only the app, nothing else).
// Usage:  node tools/build-site.js [outputFolder]     (default: _site)
//
// It uses an ALLOW list: a new file or folder is NOT public until it is added here on purpose.
// tests/static-checks.js fails if a top-level folder is in neither list, so nothing is forgotten.
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '..');

const PUBLIC_DIRS = ['admin', 'attendance', 'css', 'icons', 'js', 'labor', 'punch', 'reports', 'templates'];
const PUBLIC_ROOT_FILES = [/\.html$/, /^manifest\.json$/, /^sw\.js$/, /^CNAME$/];
// Known to be private (never published). Anything else at the top level must be classified in one of the two lists.
const PRIVATE_ENTRIES = ['.git', '.github', '.gitignore', 'node_modules', 'tests', 'tools', 'supabase', 'ROADMAP.md', 'README.md', '_site'];

function build(out) {
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });
  for (const e of fs.readdirSync(ROOT, { withFileTypes: true })) {
    if (e.isDirectory() && PUBLIC_DIRS.includes(e.name)) fs.cpSync(path.join(ROOT, e.name), path.join(out, e.name), { recursive: true });
    else if (e.isFile() && PUBLIC_ROOT_FILES.some(re => re.test(e.name))) fs.copyFileSync(path.join(ROOT, e.name), path.join(out, e.name));
  }
  fs.writeFileSync(path.join(out, '.nojekyll'), '');
}

function unclassified() {
  return fs.readdirSync(ROOT, { withFileTypes: true }).map(e => e.name).filter(name =>
    !PRIVATE_ENTRIES.includes(name) && !PUBLIC_DIRS.includes(name) && !PUBLIC_ROOT_FILES.some(re => re.test(name)));
}

module.exports = { build, unclassified, PUBLIC_DIRS, PRIVATE_ENTRIES };
if (require.main === module) {
  const out = path.resolve(process.argv[2] || path.join(ROOT, '_site'));
  build(out);
  console.log('Built public site in ' + out);
}
