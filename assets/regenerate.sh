#!/usr/bin/env bash
# Regenerate the bar-legible Kuma marks from the upstream logo.
#
# upstream-icon.svg is louislam/uptime-kuma public/icon.svg, verbatim (MIT).
# Two changes make it readable at 15-26px in a status bar:
#
#   viewBox 0 0 640 640 -> 85 85 470 470   the artwork occupies only the middle
#                                          422x372 of the canvas; the rest is
#                                          empty halo that shrinks the mark
#   stroke-width 200 -> 44                 the translucent halo is ~1/3 of the
#                                          icon at bar sizes and blurs the shape
#
# The alert mark swaps the gradient stops for the same colors hue-rotated to
# red (identical saturation and lightness), so it reads as the same logo with
# red shading rather than a flat red tint.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

tighten() { sed 's|viewBox="0 0 640 640"|viewBox="85 85 470 470"|; s|stroke-width: 200|stroke-width: 44|' upstream-icon.svg; }

tighten > uptime-kuma.svg
tighten | sed 's|#5CDD8B|#DD5A5A|; s|#86E6A9|#E78383|' > uptime-kuma-alert.svg
echo "wrote uptime-kuma.svg uptime-kuma-alert.svg"
