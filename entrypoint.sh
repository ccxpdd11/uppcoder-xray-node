#!/bin/sh
# Runtime wrapper for KamuiDash (DEPLOY_MEMORY.md Sec.5 route A, Node entry).
# KamuiDash is a pure-source Node.js PaaS (no Dockerfile): the dashboard runs
# `npm install` (setup) then `npm start` (server.js), and server.js spawns
# this script. server.js also serves /health and proxies /ws (or /xhttp) to
# xray, which listens on a LOCAL port (127.0.0.1) only -- never on $PORT
# directly, so the health check and the proxy in server.js own $PORT.
# - Downloads xray-core official release at runtime if no binary is present.
#   Download prefers the Node fetcher (pure core modules, no curl/wget/unzip
#   needed) because a Node container is guaranteed to have Node but may lack
#   curl/wget; falls back to curl, then wget.
# - Generates config.json from env: PORT / UUID / WS_PATH / XHTTP_PATH / TRANSPORT.
# - Listens on $PORT (set by server.js to the local XRAY_PORT, never hardcoded
#   to the platform port; server.js owns $PORT).
# - Default transport: VLESS+WS+TLS (TLS is terminated by the platform edge).
#   Fallback rule: if WS is broken twice (400 / 101-then-drop / H2 downgrade),
#   redeploy with TRANSPORT=xhttp (VLESS+XHTTP packet-up + TLS, ALPN http/1.1).
# - UUID is NEVER written into this repo. Set it as a platform env var / secret,
#   and store the per-node value only in a local 600-permission credential file.
set -eu
PORT="${PORT:-8080}"
UUID="${UUID:-}"
WS_PATH="${WS_PATH:-/ws}"
XHTTP_PATH="${XHTTP_PATH:-/xhttp}"
TRANSPORT="${TRANSPORT:-ws}"
XRAY_VERSION="${XRAY_VERSION:-v26.11.9}"
if [ -z "$UUID" ]; then echo "ERROR: UUID env var is required (set it in the platform dashboard, never in a file)" >&2; exit 1; fi
case "$UUID" in
  ????????-????-????-????-????????????) ;;
  *) echo "ERROR: UUID does not look like a UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)" >&2; exit 1 ;;
esac
case "$TRANSPORT" in ws|xhttp) ;; *) echo "ERROR: TRANSPORT must be ws or xhttp" >&2; exit 1 ;; esac
# Locate or download the xray binary.
XRAY_BIN=""
for cand in ./xray /usr/local/bin/xray /usr/bin/xray; do
  if [ -x "$cand" ]; then XRAY_BIN="$cand"; break; fi
done
if [ -z "$XRAY_BIN" ]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) PKG="Xray-linux-64.zip" ;;
    aarch64|arm64) PKG="Xray-linux-arm64-v8a.zip" ;;
    armv7l) PKG="Xray-linux-arm32-v7a.zip" ;;
    *) PKG="Xray-linux-64.zip" ;;
  esac
  URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${PKG}"
  echo "Downloading xray-core ${XRAY_VERSION} (${PKG}) ..."
  mkdir -p /tmp/xray-dl
  if command -v node >/dev/null 2>&1; then
    # Pure-Node downloader + extractor (https + zlib core modules only).
    # Follows up to 5 redirects, then scans ZIP local-file headers for the
    # entry named "xray" (stored or deflate) and writes it out executable.
    cat > /tmp/xray-fetch.js <<'NODEEOF'
const fs = require('fs');
const https = require('https');
const zlib = require('zlib');
function fetch(url, left) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'xray-fetch' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        if (left <= 0) return reject(new Error('too many redirects'));
        res.resume();
        return resolve(fetch(res.headers.location, left - 1));
      }
      if (res.statusCode !== 200) return reject(new Error('download HTTP ' + res.statusCode));
      const parts = [];
      res.on('data', (c) => parts.push(c));
      res.on('end', () => resolve(Buffer.concat(parts)));
      res.on('error', reject);
    }).on('error', reject);
  });
}
function extract(zip, dest) {
  let off = 0;
  while (off + 30 <= zip.length) {
    if (zip.readUInt32LE(off) !== 0x04034b50) break;
    const flags = zip.readUInt16LE(off + 6);
    const method = zip.readUInt16LE(off + 8);
    const size = zip.readUInt32LE(off + 18);
    const nLen = zip.readUInt16LE(off + 26);
    const xLen = zip.readUInt16LE(off + 28);
    const name = zip.toString('utf8', off + 30, off + 30 + nLen);
    const start = off + 30 + nLen + xLen;
    if (flags & 0x08) throw new Error('zip uses data descriptors, unsupported');
    const data = zip.subarray(start, start + size);
    if (name === 'xray') {
      let bin;
      if (method === 0) bin = data;
      else if (method === 8) bin = zlib.inflateRawSync(data);
      else throw new Error('unsupported compression method ' + method);
      fs.mkdirSync(dest, { recursive: true });
      fs.writeFileSync(dest + '/xray', bin, { mode: 0o755 });
      return true;
    }
    off = start + size;
  }
  return false;
}
(async () => {
  const url = process.argv[2];
  const dest = process.argv[3];
  if (!url || !dest) { console.error('usage: node xray-fetch.js <url> <destDir>'); process.exit(1); }
  const zip = await fetch(url, 5);
  if (!extract(zip, dest)) { console.error('xray entry not found in zip'); process.exit(1); }
  console.log('xray binary extracted to ' + dest + '/xray');
})().catch((e) => { console.error('ERROR: ' + e.message); process.exit(1); });
NODEEOF
    node /tmp/xray-fetch.js "$URL" /tmp/xray-dl
    XRAY_BIN="/tmp/xray-dl/xray"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o /tmp/xray-dl/xray.zip "$URL"
    if command -v unzip >/dev/null 2>&1; then
      unzip -o -q /tmp/xray-dl/xray.zip -d /tmp/xray-dl
    else
      python3 -c "import zipfile; zipfile.ZipFile('/tmp/xray-dl/xray.zip').extractall('/tmp/xray-dl')"
    fi
    chmod +x /tmp/xray-dl/xray
    XRAY_BIN="/tmp/xray-dl/xray"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O /tmp/xray-dl/xray.zip "$URL"
    if command -v unzip >/dev/null 2>&1; then
      unzip -o -q /tmp/xray-dl/xray.zip -d /tmp/xray-dl
    else
      python3 -c "import zipfile; zipfile.ZipFile('/tmp/xray-dl/xray.zip').extractall('/tmp/xray-dl')"
    fi
    chmod +x /tmp/xray-dl/xray
    XRAY_BIN="/tmp/xray-dl/xray"
  else echo "ERROR: need node, curl or wget to fetch xray-core" >&2; exit 1; fi
fi
echo "xray: $($XRAY_BIN version | head -n 1)"
# Generate config.json from env (no secrets are echoed).
# NOTE: listen is 127.0.0.1 -- xray is only reached via the server.js proxy
# (which owns $PORT and serves /health); it is never exposed directly.
if [ "$TRANSPORT" = "xhttp" ]; then
  STREAM="\"network\": \"xhttp\", \"xhttpSettings\": {\"path\": \"$XHTTP_PATH\", \"mode\": \"packet-up\"}"
  LISTEN_PATH="$XHTTP_PATH"
else
  STREAM="\"network\": \"ws\", \"wsSettings\": {\"path\": \"$WS_PATH\"}"
  LISTEN_PATH="$WS_PATH"
fi
cat > config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {"clients": [{"id": "$UUID", "flow": ""}], "decryption": "none"},
      "streamSettings": {$STREAM}
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ]
}
EOF
echo "ready: transport=$TRANSPORT path=$LISTEN_PATH port=$PORT (TLS terminated by platform edge; force ALPN http/1.1 on the client when using xhttp)"
exec "$XRAY_BIN" -config config.json
