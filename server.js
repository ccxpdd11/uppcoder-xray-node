// KamuiDash Node wrapper + reverse proxy + /health endpoint.
// Why a proxy is needed (KamuiDash docs, Troubleshooting > Health Check Fails):
// KamuiDash does an HTTP health check on the configured endpoint and expects
// HTTP 200; "Build succeeds but app doesn't become running" if the endpoint
// does not exist. xray alone cannot serve /health (it only speaks VLESS on
// /ws or /xhttp, and returns 404 elsewhere), so this wrapper:
//   - Spawns entrypoint.sh (xray) on a LOCAL port (XRAY_PORT, default 18080).
//   - Listens on $PORT (platform-assigned, set by KamuiDash by default).
//   - GET /health -> 200 {"status":"ok"} (health check).
//   - GET / (and anything else) -> 404.
//   - WebSocket upgrade on WS_PATH (/ws) -> proxies raw bytes to xray.
//   - HTTP request on XHTTP_PATH (/xhttp) when TRANSPORT=xhttp -> proxies
//     the HTTP request (method, path, headers, body) to xray and pipes the
//     response back (XHTTP is HTTP-based, not a WS upgrade).
// It does NOT bind $PORT itself for xray; xray is only reachable via this proxy.
// UUID is NEVER in this repo. Set it as a platform env var / secret.
const { spawn } = require("child_process");
const http = require("http");
const net = require("net");
const path = require("path");

const PORT = parseInt(process.env.PORT || "8080", 10);
const XRAY_PORT = parseInt(process.env.XRAY_PORT || "18080", 10);
const WS_PATH = process.env.WS_PATH || "/ws";
const XHTTP_PATH = process.env.XHTTP_PATH || "/xhttp";
const TRANSPORT = process.env.TRANSPORT || "ws";

// Spawn xray via entrypoint.sh, on the local port (not $PORT).
const child = spawn("sh", [path.join(__dirname, "entrypoint.sh")], {
  stdio: "inherit",
  env: Object.assign({}, process.env, { PORT: String(XRAY_PORT) }),
});
child.on("exit", (code, signal) => {
  console.log(`entrypoint exited code=${code} signal=${signal}`);
  process.exit(code === null ? 1 : code);
});
process.on("SIGTERM", () => child.kill("SIGTERM"));
process.on("SIGINT", () => child.kill("SIGINT"));

// Public HTTP server on $PORT (platform-assigned).
const server = http.createServer((req, res) => {
  const urlPath = (req.url || "/").split("?")[0];
  if (urlPath === "/health" || urlPath === "/health/") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }
  // XHTTP fallback: forward the HTTP request (method, path, headers, body)
  // to xray's local port and pipe the response back.
  if (TRANSPORT === "xhttp" && urlPath === XHTTP_PATH) {
    const proxyReq = http.request(
      {
        host: "127.0.0.1",
        port: XRAY_PORT,
        method: req.method,
        path: req.url,
        headers: req.headers,
      },
      (proxyRes) => {
        res.writeHead(proxyRes.statusCode || 502, proxyRes.headers);
        proxyRes.pipe(res);
      }
    );
    proxyReq.on("error", () => {
      if (!res.headersSent) res.writeHead(502, { "Content-Type": "text/plain" });
      res.end("bad gateway");
    });
    req.pipe(proxyReq);
    return;
  }
  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("not found");
});

// WebSocket upgrade on WS_PATH: proxy raw bytes to xray's local port.
server.on("upgrade", (req, socket, head) => {
  const urlPath = (req.url || "").split("?")[0];
  if (TRANSPORT !== "ws" || urlPath !== WS_PATH) {
    socket.destroy();
    return;
  }
  const proxy = net.connect(XRAY_PORT, "127.0.0.1", () => {
    // Forward the original upgrade request (method + path + all headers).
    let out = req.method + " " + req.url + " HTTP/" + req.httpVersion + "\r\n";
    for (const k of Object.keys(req.headers)) {
      out += k + ": " + req.headers[k] + "\r\n";
    }
    out += "\r\n";
    proxy.write(out);
    if (head && head.length) proxy.write(head);
    socket.pipe(proxy);
    proxy.pipe(socket);
  });
  proxy.on("error", () => {
    try { socket.destroy(); } catch (_) {}
  });
  socket.on("error", () => {
    try { proxy.destroy(); } catch (_) {}
  });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(
    "kamui wrapper listening on 0.0.0.0:" + PORT +
    " (xray on 127.0.0.1:" + XRAY_PORT +
    ", transport=" + TRANSPORT + ")"
  );
});
