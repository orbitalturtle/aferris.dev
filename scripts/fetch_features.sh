#!/usr/bin/env bash
#
# Daily snapshot of BOLT 9 feature adoption across the public Lightning network.
# Primary path:   lncli describegraph  (full-graph view, ~17k nodes).
# Fallback path:  fetch_features.py    (mempool.space sample, when lncli is down).
#
# Both paths write the same schema to:
#   static/data/feature-adoption/snapshots.json   (time series for sparklines)
#   static/data/feature-adoption/latest-nodes.json (top-N per-node detail for the constellation)
#
# After a successful run, git-commits the changed data files so Cloudflare Pages rebuilds.

set -euo pipefail

# Cron has a minimal PATH; add common locations so lncli, jq, git, python3 resolve.
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/go/bin:$HOME/bin:$PATH"

ts() { date -u +"%Y-%m-%d %H:%M:%S"; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$REPO_DIR/static/data/feature-adoption"
AGG_FILE="$DATA_DIR/snapshots.json"
NODES_FILE="$DATA_DIR/latest-nodes.json"
DATE="$(date -u +%Y-%m-%d)"
TOP_N=300  # how many nodes to keep for the constellation

mkdir -p "$DATA_DIR"

# Features we track. Each row: name | even_bit | odd_bit
# Order matters — keeps JSON output stable for git diffs.
TRACKED=(
  "onion_messages|38|39"
  "route_blinding|24|25"
  "keysend|54|55"
)

#
# --- Primary path: lncli describegraph ---
#
run_lncli() {
  command -v lncli >/dev/null 2>&1 || { echo "[$(ts)] lncli not on PATH"; return 1; }
  echo "[$(ts)] Trying lncli describegraph..."
  if ! GRAPH="$(lncli describegraph 2>/tmp/lncli-err)"; then
    echo "[$(ts)] lncli failed:"; cat /tmp/lncli-err >&2
    return 1
  fi
  TOTAL=$(echo "$GRAPH" | jq '.nodes | length')
  if [ "$TOTAL" -eq 0 ]; then
    echo "[$(ts)] lncli returned 0 nodes (graph still syncing?)"; return 1
  fi
  echo "[$(ts)] lncli OK: $TOTAL nodes in graph"

  # Build aggregate counts in a single jq pass.
  local count_args=()
  for row in "${TRACKED[@]}"; do
    IFS='|' read -r name even odd <<<"$row"
    count_args+=("--arg" "n_$name" "$name" "--arg" "e_$name" "$even" "--arg" "o_$name" "$odd")
  done

  # Compute aggregate snapshot
  local jq_filter='
    . as $g |
    ($g.nodes | length) as $total |
    {
      date: $date,
      source: "lncli describegraph",
      sample_strategy: "full public graph",
      sample_size: $total,
      failed_fetches: 0,
      features: {}
    }
  '
  for row in "${TRACKED[@]}"; do
    IFS='|' read -r name even odd <<<"$row"
    jq_filter+="
      | .features.\"$name\" = {
          bits: [$even, $odd],
          count: ([\$g.nodes[] | select(.features | has(\"$even\") or has(\"$odd\"))] | length),
          percentage: ((([\$g.nodes[] | select(.features | has(\"$even\") or has(\"$odd\"))] | length) * 10000 / \$total) | . / 100)
        }
    "
  done

  AGG=$(echo "$GRAPH" | jq --arg date "$DATE" "$jq_filter")
  echo "[$(ts)] Aggregate built:"
  echo "$AGG" | jq '.features'

  # Per-node detail: top-N by channel count.
  # Channel counts come from .edges; we aggregate then join with .nodes.
  echo "[$(ts)] Building per-node detail (top $TOP_N by channels)..."
  NODES_DETAIL=$(echo "$GRAPH" | jq --argjson n "$TOP_N" '
    ([.edges[] | (.node1_pub, .node2_pub)] | group_by(.) | map({key: .[0], value: length}) | from_entries) as $chmap |
    ([.edges[] | {key: .node1_pub, cap: (.capacity | tonumber)}, {key: .node2_pub, cap: (.capacity | tonumber)}]
      | group_by(.key) | map({key: .[0].key, value: (map(.cap) | add)}) | from_entries) as $capmap |
    {
      date: $date,
      sample_size: ($chmap | length),
      tracked_features: ["onion_messages", "route_blinding", "keysend"],
      nodes: ([.nodes[] | {
        pubkey_short: (.pub_key[0:16]),
        alias: .alias,
        channels: ($chmap[.pub_key] // 0),
        capacity_sat: ($capmap[.pub_key] // 0),
        supports: ([
          (if (.features | has("38") or has("39")) then "onion_messages" else empty end),
          (if (.features | has("24") or has("25")) then "route_blinding" else empty end),
          (if (.features | has("54") or has("55")) then "keysend" else empty end)
        ])
      }] | sort_by(-.channels) | .[0:$n])
    }
  ' --arg date "$DATE")

  # Merge aggregate into snapshots.json (idempotent on date)
  [ -f "$AGG_FILE" ] || echo '{"schema_version":1,"snapshots":[]}' > "$AGG_FILE"
  jq --argjson new "$AGG" '
    .snapshots = ([.snapshots[] | select(.date != $new.date)] + [$new] | sort_by(.date))
  ' "$AGG_FILE" > "$AGG_FILE.tmp" && mv "$AGG_FILE.tmp" "$AGG_FILE"

  echo "$NODES_DETAIL" > "$NODES_FILE"
  echo "[$(ts)] Wrote $AGG_FILE and $NODES_FILE"
  return 0
}

#
# --- Fallback path: Python + mempool.space ---
#
run_python() {
  command -v python3 >/dev/null 2>&1 || { echo "[$(ts)] python3 not on PATH"; return 1; }
  echo "[$(ts)] Falling back to mempool.space sample..."
  python3 "$REPO_DIR/scripts/fetch_features.py" \
    --out "$AGG_FILE" \
    --nodes-out "$NODES_FILE" \
    --limit 300 \
    --delay 0.12
}

#
# --- Run ---
#
if run_lncli; then
  echo "[$(ts)] lncli path succeeded."
elif run_python; then
  echo "[$(ts)] python fallback succeeded."
else
  echo "[$(ts)] ERROR: both data sources failed. Not committing."
  exit 1
fi

#
# --- Commit & push if anything changed ---
#
cd "$REPO_DIR"
if git diff --quiet -- "$AGG_FILE" "$NODES_FILE"; then
  echo "[$(ts)] No data changes — nothing to commit."
else
  echo "[$(ts)] Committing and pushing..."
  git add "$AGG_FILE" "$NODES_FILE"
  git commit -m "data: feature adoption snapshot for $DATE"
  git push
  echo "[$(ts)] Done — Cloudflare Pages will rebuild shortly."
fi
