#!/usr/bin/env bash
# Write ~/.config/omarchy/uptime-kuma.json from a JSON object on stdin.
#
# The setup panel pipes {"url":…,"apiKey":…} in here. The API key
# goes over stdin, never argv, so it never shows up in /proc or a shell history.
#
# An empty/absent apiKey keeps whatever key is already stored, which lets the
# panel prefill its form without ever displaying the secret.
#
# Prints "ok" on success, or an error line on stderr with a non-zero exit.

set -uo pipefail

config="${UPTIME_KUMA_CONFIG:-$HOME/.config/omarchy/uptime-kuma.json}"

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

# One JSON object on one line — JSON.stringify never emits a raw newline, so a
# single read keeps this working whether or not the caller closes stdin.
IFS= read -r input || true
[[ -z "${input:-}" ]] && die "No configuration received"

jq -e . >/dev/null 2>&1 <<<"$input" || die "Malformed configuration"

url="$(jq -r '.url // "" | sub("/+$"; "")' <<<"$input")"
[[ -z "$url" ]] && die "The instance URL is required"
[[ "$url" == https://* ]] || die "The URL must start with https://"
[[ "$(jq -r '(.insecure // false) | tostring' <<<"$input")" != "true" ]] || \
  die "TLS certificate verification cannot be disabled"

# Keep the stored key when the panel submits an empty one.
existing_key=""
if [[ -r "$config" ]]; then
  existing_key="$(jq -r '.apiKey // ""' "$config" 2>/dev/null)"
fi

mkdir -p "$(dirname "$config")" || die "Cannot create $(dirname "$config")"

tmp="$(mktemp "$config.XXXXXX")" || die "Cannot write next to $config"
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"

jq -n \
  --arg url "$url" \
  --arg key "$(jq -r '.apiKey // ""' <<<"$input")" \
  --arg existing "$existing_key" \
  '{
    url: $url,
    apiKey: (if $key == "" then $existing else $key end)
  }' >"$tmp" || die "Could not build the configuration"

mv -f "$tmp" "$config" || die "Could not save $config"
trap - EXIT
chmod 600 "$config"

printf 'ok\n'
