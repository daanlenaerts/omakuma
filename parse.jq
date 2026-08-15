# Turn Uptime Kuma's Prometheus /metrics output into the compact state object
# the bar widget consumes. Input is the raw metrics body (jq -Rs).

def unesc:
  gsub("\\\\\"" ; "\"") | gsub("\\\\n" ; "\n") | gsub("\\\\\\\\" ; "\\");

# Pull a single Prometheus label out of a label set, honouring backslash escapes.
def lab($labels; $key):
  ($labels | capture($key + "=\"(?<v>(?:[^\"\\\\]|\\\\.)*)\"") | .v | unesc) // null;

def num:
  if type == "string" and test("^-?[0-9]+(\\.[0-9]+)?([eE][-+]?[0-9]+)?$")
  then (tonumber | floor)
  else null
  end;

def statusName:
  if . == 0 then "down"
  elif . == 1 then "up"
  elif . == 2 then "pending"
  elif . == 3 then "maintenance"
  else "unknown"
  end;

def blank: if . == null or . == "" or . == "null" then null else . end;

[splits("\n")]
| map(select(startswith("monitor_status{") or startswith("monitor_response_time{")))
| map(capture("^(?<metric>[a-z_]+)\\{(?<labels>.*)\\}[ \t]+(?<value>\\S+)$"))
| map(. + {
    mname: (lab(.labels; "monitor_name") // "unknown"),
    mtype: (lab(.labels; "monitor_type") | blank),
    murl: (lab(.labels; "monitor_url") | blank),
    mhost: (lab(.labels; "monitor_hostname") | blank)
  })
| group_by(.mname)
| map(
    (map(select(.metric == "monitor_status")) | .[0]) as $s
    | (map(select(.metric == "monitor_response_time")) | .[0]) as $rt
    | (if $s == null then -1 else ($s.value | num // -1) end) as $code
    | {
        name: .[0].mname,
        type: .[0].mtype,
        url: .[0].murl,
        hostname: .[0].mhost,
        status: ($code | statusName),
        responseTime: (if $rt == null then null else ($rt.value | num) end)
      }
  )
# Anything that is not up sorts above everything that is, worst first.
| sort_by(
    (if .status == "down" then 0
     elif .status == "pending" then 1
     elif .status == "maintenance" then 2
     elif .status == "up" then 4
     else 3 end),
    (.name | ascii_downcase)
  )
| {
    ok: true,
    error: "",
    dashboard: $dashboard,
    config: $config,
    configured: true,
    monitors: .,
    total: length,
    up: (map(select(.status == "up")) | length),
    down: (map(select(.status == "down")) | length),
    pending: (map(select(.status == "pending")) | length),
    maintenance: (map(select(.status == "maintenance")) | length)
  }
