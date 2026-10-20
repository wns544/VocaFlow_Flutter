// Localhost-only static fixture server; no credentials or production network.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(process.argv[2] || 'build/browser-storage-lab');
const port = Number(process.argv[3] || 8769);
http.createServer((req, res) => {
  const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  const target = path.resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname));
  if (!target.startsWith(root + path.sep)) { res.writeHead(403).end(); return; }
  fs.readFile(target, (err, data) => {
    if (err) { res.writeHead(404).end(); return; }
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Content-Type', ({'.js':'text/javascript','.html':'text/html','.wasm':'application/wasm','.json':'application/json'})[path.extname(target)] || 'application/octet-stream');
    res.end(data);
  });
}).listen(port, '127.0.0.1', () => console.log(`Isolated lab: http://127.0.0.1:${port}`));
