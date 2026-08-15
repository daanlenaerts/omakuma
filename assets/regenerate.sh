#!/usr/bin/env bash
# Derive the bar mark from the upstream Uptime Kuma logo.
#
# uptime-kuma.svg is louislam/uptime-kuma public/icon.svg, verbatim (MIT).
#
# The only change: the logo's 200px translucent halo is drawn in near-white,
# which is decoration for a light background. The bar recolours the mark to a
# single theme colour (like a symbolic tray icon), and under that recolouring
# the halo becomes a heavy dark ring that swamps the shape at 15-26px. Dropping
# the stroke leaves the artwork's own path untouched.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

sed 's|stroke-width: 200|stroke-width: 0|' uptime-kuma.svg > uptime-kuma-mark.svg
echo "wrote uptime-kuma-mark.svg"
