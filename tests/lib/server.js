// Minimal static file server for the tests (serves the repo root on localhost, which selects the STAGING database).
const http = require('http'), fs = require('fs'), path = require('path');
const ROOT = process.env.SITE_ROOT ? path.resolve(process.env.SITE_ROOT) : path.resolve(__dirname, '..', '..');   // SITE_ROOT: test the built public site instead of the repo
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.svg': 'image/svg+xml' };
let counter = 0, down = false;   // down = true: drop every connection, like a device with no network   // /__test/counter.js returns a different number on every request (used to prove network-first)
module.exports = function start(port = 0) {
  return new Promise(resolve => {
    const srv = http.createServer((req, res) => {
      if (down) return req.socket.destroy();
      let p = decodeURIComponent(req.url.split('?')[0]); if (p.endsWith('/')) p += 'index.html';
      if (p === '/__test/counter.js') { counter++; res.writeHead(200, { 'content-type': 'text/javascript', 'cache-control': 'no-store' }); return res.end('window.__counter = ' + counter + ';'); }
      const f = path.join(ROOT, p);
      if (!f.startsWith(ROOT) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end('not found'); }
      res.writeHead(200, { 'content-type': TYPES[path.extname(f)] || 'application/octet-stream', 'cache-control': 'no-store' });
      fs.createReadStream(f).pipe(res);
    }).listen(port, '127.0.0.1', () => resolve({ srv, url: `http://localhost:${srv.address().port}`, setDown: v => { down = v; } }));
  });
};
