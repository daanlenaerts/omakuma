#!/usr/bin/env bash
# Emit the status of every active Uptime Kuma monitor as compact JSON.
#
# Reads ~/.config/omarchy/uptime-kuma.json, which the plugin's own setup panel
# writes (see save-config.sh). The file lives outside the plugin directory so
# the API key never lands in a dotfiles repo:
#
#   { "url": "https://kuma.example.com", "apiKey": "uk1_...", "insecure": false }
#
# UPTIME_KUMA_URL / UPTIME_KUMA_API_KEY override the config file when set.
#
# The emitted `config` object never contains the API key itself, only whether
# one is stored, so the panel can prefill its form without echoing the secret.

set -uo pipefail

plugin_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
config="${UPTIME_KUMA_CONFIG:-$HOME/.config/omarchy/uptime-kuma.json}"

url="${UPTIME_KUMA_URL:-}"
api_key="${UPTIME_KUMA_API_KEY:-}"
insecure="false"
config_obj='{"url":"","hasKey":false,"insecure":false,"path":""}'

fail() {
  jq -cn \
    --arg error "$1" \
    --arg dashboard "$url" \
    --argjson config "$config_obj" '{
      ok: false,
      error: $error,
      dashboard: $dashboard,
      config: $config,
      configured: ($config.url != ""),
      monitors: [],
      total: 0, up: 0, down: 0, pending: 0, maintenance: 0
    }'
  exit 0
}

if [[ -r "$config" ]]; then
  mapfile -t cfg < <(jq -r '[.url // "", .apiKey // "", ((.insecure // false) | tostring)] | .[]' "$config" 2>/dev/null)
  [[ -z "$url" ]] && url="${cfg[0]:-}"
  [[ -z "$api_key" ]] && api_key="${cfg[1]:-}"
  insecure="${cfg[2]:-false}"
fi

url="${url%/}"

has_key="false"
[[ -n "$api_key" ]] && has_key="true"
config_obj="$(jq -cn \
  --arg url "$url" \
  --argjson hasKey "$has_key" \
  --argjson insecure "${insecure:-false}" \
  --arg path "$config" \
  '{url: $url, hasKey: $hasKey, insecure: $insecure, path: $path}')"

[[ -z "$url" ]] && fail "Not configured"

curl_args=(--silent --show-error --max-time 8 --user ":$api_key")
[[ "$insecure" == "true" ]] && curl_args+=(--insecure)

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

code="$(curl "${curl_args[@]}" --output "$body" --write-out '%{http_code}' "$url/metrics" 2>/dev/null)" || code="000"

case "$code" in
  200) ;;
  000) fail "Unreachable — check the URL, or tick self-signed if it uses a private certificate" ;;
  401 | 403) fail "Unauthorized — check the API key" ;;
  404) fail "No /metrics endpoint here — is this an Uptime Kuma instance?" ;;
  *) fail "HTTP $code" ;;
esac

parsed="$(jq -Rs \
  --arg dashboard "$url" \
  --argjson config "$config_obj" \
  -f "$plugin_dir/parse.jq" <"$body" 2>/dev/null)" || parsed=""
[[ -z "$parsed" ]] && fail "Unreadable metrics response"

printf '%s' "$parsed" | jq -c .
