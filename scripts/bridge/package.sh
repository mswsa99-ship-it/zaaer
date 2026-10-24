#!/usr/bin/env bash
# Builds the reception-computer WhatsApp program for Windows, published next to the website:
#   <out>/zaaer-whatsapp-bridge.zip   bridge/ + its node_modules + the official node.exe (checksum-verified)
#   <out>/version.json                program version, Node version, size and SHA-256 of the zip
# Usage: scripts/bridge/package.sh <out-dir>
#   NODE_MAJOR (default 24): newest LTS of that line from nodejs.org;  NODE_VERSION=v24.x.y pins one;
#   NODE_EXE=/path/node.exe uses a local file instead (offline checks).
set -euo pipefail
OUT="${1:?usage: package.sh <out-dir>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"            # absolute: the zip below is written from inside the work folder
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NODE_MAJOR="${NODE_MAJOR:-24}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/zaaer-whatsapp-bridge"
mkdir -p "$APP/node"

cp -r "$ROOT/bridge/src" "$APP/"
cp "$ROOT/bridge/package.json" "$ROOT/bridge/package-lock.json" "$ROOT/bridge/start.bat" "$ROOT/bridge/install-startup.bat" \
   "$ROOT/bridge/uninstall-startup.bat" "$ROOT/bridge/README-AR.txt" "$APP/"
# pure-JavaScript dependencies (the same on Windows); no browser download: the computer's own Chrome/Edge is used
(cd "$APP" && PUPPETEER_SKIP_DOWNLOAD=1 npm ci --omit=optional --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error)
# source maps and type declarations are not needed to run (smaller download)
find "$APP/node_modules" -type f \( -name '*.map' -o -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' \) -delete

if [ -n "${NODE_EXE:-}" ]; then
  cp "$NODE_EXE" "$APP/node/node.exe"; V="local"
else
  V="${NODE_VERSION:-$(curl -fsSL https://nodejs.org/dist/index.json | python3 -c "
import json, sys
rows = [r for r in json.load(sys.stdin) if r['version'].startswith('v${NODE_MAJOR}.')]
lts = [r for r in rows if r.get('lts')]
print((lts or rows)[0]['version'])")}"
  curl -fsSL -o "$WORK/node.exe" "https://nodejs.org/dist/$V/win-x64/node.exe"
  SUM="$(curl -fsSL "https://nodejs.org/dist/$V/SHASUMS256.txt" | awk '$2 == "win-x64/node.exe" { print $1 }')"
  [ -n "$SUM" ] || { echo "no checksum for win-x64/node.exe in $V" >&2; exit 1; }
  echo "$SUM  $WORK/node.exe" | sha256sum -c - >/dev/null
  mv "$WORK/node.exe" "$APP/node/node.exe"
fi
echo "$V" > "$APP/node/VERSION"

rm -f "$OUT/zaaer-whatsapp-bridge.zip"
(cd "$WORK" && zip -q -r -9 -X "$OUT/zaaer-whatsapp-bridge.zip" zaaer-whatsapp-bridge)
python3 - "$OUT/zaaer-whatsapp-bridge.zip" "$ROOT/bridge/package.json" "$V" > "$OUT/version.json" <<'PY'
import hashlib, json, os, sys, datetime
z, pkg, node = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({"version": json.load(open(pkg))["version"], "node": node, "bytes": os.path.getsize(z),
                  "sha256": hashlib.sha256(open(z, "rb").read()).hexdigest(),
                  "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}, ensure_ascii=False))
PY
echo "WhatsApp bridge: $OUT/zaaer-whatsapp-bridge.zip ($(du -h "$OUT/zaaer-whatsapp-bridge.zip" | cut -f1), node $V)"
