#!/usr/bin/env bash
# Release proof 3.6 (الشعار وملفات التطبيق): the static half of the acceptance — SVG logo, icons 32/192/512,
# a maskable icon, a share image, and a manifest whose icon files all exist with the declared sizes.
# The phone-install half (لقطة على جوال حقيقي) is NOT covered here: see acceptance/release-proof/device-browser-checklist-3.6-7.6.md.
# Usage: bash tests/release-proof/check_app_assets.sh   (run from the repo root; read-only)
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { # name, ok(0/1), detail
  if [ "$2" = 0 ]; then echo "PASS | $1 | $3"; pass=$((pass+1)); else echo "FAIL | $1 | $3"; fail=$((fail+1)); fi
}
png_size() { python3 - "$1" <<'PY'
import struct, sys
try:
    with open(sys.argv[1], 'rb') as f:
        head = f.read(24)
    if head[:8] != b'\x89PNG\r\n\x1a\n':
        print('not-a-png'); sys.exit(0)
    w, h = struct.unpack('>II', head[16:24])
    print(f'{w}x{h}')
except OSError:
    print('missing')
PY
}
[ -f public/favicon.svg ] && head -c 200 public/favicon.svg | grep -qi '<svg'; check 'RA36-01 SVG logo present and well-formed' $? "public/favicon.svg"
for size in 32 192 512; do
  got=$(png_size "public/icon-$size.png")
  [ "$got" = "${size}x${size}" ]; check "RA36-02 icon $size px exists with exact dimensions" $? "public/icon-$size.png -> $got"
done
got=$(png_size public/icon-maskable-512.png)
[ "$got" = "512x512" ]; check 'RA36-03 maskable icon exists (512x512)' $? "public/icon-maskable-512.png -> $got"
got=$(png_size public/og-image.png)
case "$got" in missing|not-a-png) ok=1;; *) ok=0;; esac
check 'RA36-04 share image (og-image.png) exists as PNG' $ok "public/og-image.png -> $got"
python3 - <<'PY'
import json, os, sys
try:
    m = json.load(open('public/manifest.webmanifest'))
    icons = m.get('icons', [])
    missing = [i['src'] for i in icons if not os.path.exists(os.path.join('public', i['src']))]
    has_maskable = any('maskable' in i.get('purpose', '') for i in icons)
    ok = not missing and has_maskable and len(icons) >= 2
    print('PASS | RA36-05 manifest lists >=2 icons incl. maskable, every file exists | ' + (f'missing={missing}' if missing else 'all manifest icons resolve') if ok else f'FAIL | RA36-05 manifest incomplete | missing={missing} maskable={has_maskable}')
    sys.exit(0 if ok else 1)
except Exception as e:
    print(f'FAIL | RA36-05 manifest readable | {e}')
    sys.exit(1)
PY
[ $? = 0 ] && pass=$((pass+1)) || fail=$((fail+1))
echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
