#!/usr/bin/env bash
#
# Daily snapshot of option_onion_messages (feature bit 38/39) adoption
# across the public Lightning network. Reads from the local LND node via
# lncli, appends today's stats to static/data/onion-messages.json, and
# commits + pushes so Cloudflare Pages rebuilds.

set -euo pipefail

# Cron has a minimal PATH; add common locations so lncli, jq, git resolve.
# Adjust the first entry to wherever `which lncli` reports on this machine.
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/go/bin:$HOME/bin:$PATH"

ts() { date -u +"%Y-%m-%d %H:%M:%S"; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_FILE="$REPO_DIR/static/data/onion-messages.json"
DATE="$(date -u +%Y-%m-%d)"

echo "[$(ts)] Fetching network graph from lncli..."
GRAPH="$(lncli describegraph)"

TOTAL=$(echo "$GRAPH" | jq '.nodes | length')
ONION=$(echo "$GRAPH" | jq '[.nodes[] | select(.features | has("38") or has("39"))] | length')

if [ "$TOTAL" -eq 0 ]; then
  echo "[$(ts)] ERROR: No nodes returned from lncli describegraph; aborting."
  exit 1
fi

PCT=$(jq -n --argjson onion "$ONION" --argjson total "$TOTAL" '(($onion * 10000 / $total) | . / 100)')
echo "  Total nodes:        $TOTAL"
echo "  Onion-msg-capable:  $ONION"
echo "  Percentage:         $PCT%"

ENTRY=$(jq -n \
  --arg date "$DATE" \
  --argjson total "$TOTAL" \
  --argjson onion "$ONION" \
  --argjson pct "$PCT" \
  '{date: $date, total_nodes: $total, onion_msg_nodes: $onion, percentage: $pct}')

[ -f "$DATA_FILE" ] || echo "[]" > "$DATA_FILE"

echo "[$(ts)] Writing entry for $DATE to $DATA_FILE"
jq --argjson new "$ENTRY" \
  '[.[] | select(.date != $new.date)] + [$new] | sort_by(.date)' \
  "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"

cd "$REPO_DIR"
if git diff --quiet "$DATA_FILE"; then
  echo "[$(ts)] No changes to commit (data file unchanged since last run)."
else
  echo "[$(ts)] Committing and pushing..."
  git add "$DATA_FILE"
  git commit -m "data: onion messaging snapshot for $DATE"
  git push
  echo "[$(ts)] Done — Cloudflare Pages will rebuild shortly."
fi
