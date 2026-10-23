#!/usr/bin/env bash
# The reception-computer WhatsApp program: every module parses, the Windows package builds complete (offline: a
# stand-in node.exe), and the packaged dependencies load — without opening WhatsApp or a browser.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
for f in "$ROOT"/bridge/src/*.mjs; do node --check "$f"; done
head -c 4096 /dev/urandom > "$T/node.exe"
NODE_EXE="$T/node.exe" bash "$ROOT/scripts/bridge/package.sh" "$T/out" > /dev/null
(cd "$T" && unzip -q out/zaaer-whatsapp-bridge.zip)
P="$T/zaaer-whatsapp-bridge"
for f in start.bat install-startup.bat uninstall-startup.bat README-AR.txt package.json src/index.mjs src/core.mjs node/node.exe node/VERSION \
         node_modules/whatsapp-web.js/package.json node_modules/puppeteer-core/package.json; do
  [ -e "$P/$f" ] || { echo "bridge package: missing $f" >&2; exit 1; }
done
[ ! -e "$P/node_modules/puppeteer/.local-chromium" ] || { echo "bridge package: a browser was downloaded into it" >&2; exit 1; }
grep -q $'\r$' "$P/start.bat" || { echo "bridge package: start.bat needs Windows line endings" >&2; exit 1; }
python3 -c "import json,sys; v=json.load(open('$T/out/version.json')); assert len(v['sha256'])==64 and v['bytes']>0" 
(cd "$P" && node -e "
const w = require('whatsapp-web.js');
if (!w.Client || !w.LocalAuth) { console.error('whatsapp-web.js did not load'); process.exit(1); }
import('./src/core.mjs').then((m) => { if (!m.Bridge) process.exit(1); console.log('bridge package ok — whatsapp-web.js ' + w.version); });
")
