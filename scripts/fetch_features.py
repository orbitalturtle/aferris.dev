#!/usr/bin/env python3
"""
Snapshot Lightning Network feature adoption from mempool.space's public API.

Strategy: pool the connectivity / liquidity / age rankings (3 x 100 nodes) into
a deduped sample, then fetch each node's `features` array and tally adoption
for the bits we care about. The sample is channel-weighted (not a uniform
random draw of all ~17k nodes), so percentages here mean "% of well-connected
nodes," not "% of every gossip entry."

Appends today's snapshot to data/snapshots.json. Idempotent: re-running on the
same day replaces that day's entry rather than duplicating it.
"""

import argparse
import datetime as dt
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://mempool.space/api/v1/lightning"
RANKINGS = ("connectivity", "liquidity", "age")

# (display_name, feature_bits). We treat a node as supporting a feature if
# *either* the optional or compulsory bit is set in its advertised features.
# BOLT 9: https://github.com/lightning/bolts/blob/master/09-features.md
TRACKED = [
    ("onion_messages", (38, 39)),
    ("route_blinding", (24, 25)),
    ("keysend",        (54, 55)),
]

UA = "feature_visualizer/0.1 (+https://aferris.dev/onion-messages/)"


def fetch_json(url: str, timeout: int = 20):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def gather_rankings() -> dict[str, dict]:
    """Pool the rankings into a {pubkey: {alias, channels, capacity}} dict.
    Channels/capacity come from the ranking entries (the per-node detail
    endpoint doesn't include them)."""
    pool: dict[str, dict] = {}
    for ranking in RANKINGS:
        nodes = fetch_json(f"{API}/nodes/rankings/{ranking}")
        for n in nodes:
            pk = n["publicKey"]
            if pk not in pool:
                pool[pk] = {
                    "alias": n.get("alias") or "",
                    "channels": n.get("channels") or 0,
                    "capacity_sat": n.get("capacity") or 0,
                }
        print(f"  + {ranking}: {len(nodes)} nodes (running total: {len(pool)} unique)", file=sys.stderr)
    return pool


def supports(features: list[dict], bits: tuple[int, ...]) -> bool:
    bits_set = {f["bit"] for f in features}
    return any(b in bits_set for b in bits)


def snapshot(limit: int, delay: float) -> tuple[dict, list[dict]]:
    """Returns (aggregate_snapshot, per_node_detail)."""
    print("Fetching ranking pages...", file=sys.stderr)
    pool = gather_rankings()
    pubkeys = list(pool.keys())[:limit]
    print(f"Sampling {len(pubkeys)} nodes (delay={delay}s between calls)...", file=sys.stderr)

    nodes_detail: list[dict] = []
    failed = 0

    for i, pk in enumerate(pubkeys, 1):
        try:
            node = fetch_json(f"{API}/nodes/{pk}")
            feats = node.get("features", []) or []
            supports_list = [name for name, bits in TRACKED if supports(feats, bits)]
            base = pool[pk]
            nodes_detail.append({
                "pubkey_short": pk[:16],
                "alias": base["alias"],
                "channels": base["channels"],
                "capacity_sat": base["capacity_sat"],
                "supports": supports_list,
            })
        except (urllib.error.URLError, json.JSONDecodeError, KeyError) as e:
            failed += 1
            print(f"  ! {pk[:16]}… failed ({e})", file=sys.stderr)
        if i % 25 == 0:
            print(f"  ... {i}/{len(pubkeys)}", file=sys.stderr)
        time.sleep(delay)

    sampled = len(nodes_detail)
    counts = {name: 0 for name, _ in TRACKED}
    for n in nodes_detail:
        for s in n["supports"]:
            counts[s] += 1

    features = {}
    for name, bits in TRACKED:
        c = counts[name]
        features[name] = {
            "bits": list(bits),
            "count": c,
            "percentage": round(100.0 * c / sampled, 3) if sampled else 0.0,
        }

    aggregate = {
        "date": dt.date.today().isoformat(),
        "source": "mempool.space",
        "sample_strategy": "pooled top-N rankings (connectivity + liquidity + age)",
        "sample_size": sampled,
        "failed_fetches": failed,
        "features": features,
    }
    return aggregate, nodes_detail


def merge_into(path: Path, entry: dict) -> None:
    doc = {"schema_version": 1, "snapshots": []}
    if path.exists():
        doc = json.loads(path.read_text())
    snapshots = [s for s in doc.get("snapshots", []) if s["date"] != entry["date"]]
    snapshots.append(entry)
    snapshots.sort(key=lambda s: s["date"])
    doc["snapshots"] = snapshots
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--limit", type=int, default=300,
                    help="max nodes to sample (default: 300 – the deduped pool)")
    ap.add_argument("--delay", type=float, default=0.15,
                    help="seconds to sleep between per-node requests (default: 0.15)")
    ap.add_argument("--out", type=Path, default=Path(__file__).parent / "data/snapshots.json")
    ap.add_argument("--nodes-out", type=Path, default=Path(__file__).parent / "data/latest-nodes.json",
                    help="where to dump per-node detail (overwritten each run)")
    args = ap.parse_args()

    entry, nodes_detail = snapshot(args.limit, args.delay)
    print(json.dumps(entry["features"], indent=2))
    merge_into(args.out, entry)

    args.nodes_out.parent.mkdir(parents=True, exist_ok=True)
    args.nodes_out.write_text(json.dumps({
        "date": entry["date"],
        "sample_size": entry["sample_size"],
        "tracked_features": [name for name, _ in TRACKED],
        "nodes": nodes_detail,
    }, indent=2) + "\n")

    print(f"Wrote {entry['date']} → {args.out} (sampled {entry['sample_size']})", file=sys.stderr)
    print(f"Wrote per-node detail → {args.nodes_out}", file=sys.stderr)


if __name__ == "__main__":
    main()
