#!/bin/bash
# Prints Bridge's usage numbers from the endpoint in telemetry/.
# Needs BRIDGE_STATS_TOKEN (the worker's STATS_TOKEN) and BRIDGE_STATS_URL (the worker's /stats URL),
# from the environment or from .env at the repository root. Needs jq.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

: "${BRIDGE_STATS_URL:?Set BRIDGE_STATS_URL, e.g. https://bridge-usage.<account>.workers.dev/stats}"
: "${BRIDGE_STATS_TOKEN:?Set BRIDGE_STATS_TOKEN to the STATS_TOKEN secret of the worker}"

curl -fsS -H "Authorization: Bearer ${BRIDGE_STATS_TOKEN}" "$BRIDGE_STATS_URL" | jq -r '
  "Active today: \(.active.day)   this week: \(.active.week)   this month: \(.active.month)",
  "Installs: \(.installs.total) in all, \(.installs.newThisWeek) new this week",
  "Website downloads: \(.downloads.total) in all, \(.downloads.week) this week",
  "",
  "Versions (active last 30 days):", (.versions[] | "  \(.version)\t\(.installs)"),
  "macOS:", (.macOS[] | "  \(.os)\t\(.installs)"),
  "Architecture:", (.arch[] | "  \(.arch)\t\(.installs)"),
  "",
  "Day         active  new", (.daily[] | "\(.day)  \(.active)\t\(.new)")
'
