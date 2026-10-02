// Only needed inside the Claude sandbox, where the browser does not trust the egress proxy's certificate.
// Fulfils external HTTPS requests with curl (TLS verification stays ON). In CI (no HTTPS_PROXY) it does nothing.
const { execFileSync } = require('child_process');
const fs = require('fs'), os = require('os'), path = require('path');
module.exports = async function curlRoutes(context, hostRegex) {
  if (!process.env.HTTPS_PROXY) return;
  await context.route(u => hostRegex.test(u.host), async route => {
    const req = route.request();
    const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'access-control-expose-headers': '*' };
    if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pw-')); const hdr = path.join(tmp, 'h'), body = path.join(tmp, 'b');
    const args = ['-sS', '-m', '30', '-X', req.method(), '-D', hdr, '-o', body];
    for (const [k, v] of Object.entries(req.headers())) if (!/^(host|origin|referer|content-length|accept-encoding|connection|sec-|user-agent)/i.test(k)) args.push('-H', `${k}: ${v}`);
    if (req.postDataBuffer()) { fs.writeFileSync(path.join(tmp, 'd'), req.postDataBuffer()); args.push('--data-binary', '@' + path.join(tmp, 'd')); }
    args.push(req.url());
    try {
      execFileSync('curl', args);
      const h = fs.readFileSync(hdr, 'utf8').split(/\r?\n\r?\n/).filter(Boolean).pop().split(/\r?\n/);
      const status = Number(h[0].split(' ')[1]); const headers = { ...cors };
      for (const line of h.slice(1)) { const i = line.indexOf(':'); if (i > 0) { const k = line.slice(0, i).toLowerCase(); if (!['content-encoding','transfer-encoding','content-length','access-control-allow-origin'].includes(k)) headers[k] = line.slice(i + 1).trim(); } }
      await route.fulfill({ status, headers, body: fs.readFileSync(body) });
    } catch (e) { await route.abort(); }
  });
};
