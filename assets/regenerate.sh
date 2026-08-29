#!/usr/bin/env bash
# Derive the bar mark from the upstream Uptime Kuma logo.
#
# uptime-kuma.svg is louislam/uptime-kuma public/icon.svg, verbatim (MIT).
#
# The only change: the logo's 200px translucent halo is drawn in near-white,
# which is decoration for a light background. The bar draws the mark in a
# single theme colour (like a symbolic tray icon), and in one flat colour the
# halo becomes a heavy ring that swamps the shape at 15-26px. Dropping the
# stroke leaves the artwork's own path untouched.
#
# With --path, print the mark's outline as Panel.qml's `markPath`: the same
# path data with the SVG's translate(320, 320) folded into the coordinates, so
# the shape fills the artwork's 640x640 box on its own.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

sed 's|stroke-width: 200|stroke-width: 0|' uptime-kuma.svg > uptime-kuma-mark.svg

if [[ "${1:-}" == "--path" ]]; then
  python3 - <<'PY'
import re

svg = open("uptime-kuma-mark.svg").read()
path = re.search(r'\sd="([^"]+)"', svg).group(1)

out = []
for token in path.replace(",", " ").split():
    if re.fullmatch(r"[A-Za-z]", token):
        out.append(token)
    else:
        out.append(("%.2f" % (float(token) + 320.0)).rstrip("0").rstrip("."))

print(" ".join(out))
PY
else
  echo "wrote uptime-kuma-mark.svg"
fi
