#!/usr/bin/env python3
"""Per-stage latency from the app's history.jsonl.

Each history record stores the time spent in each stage, keyed by the stage's end mark:
  micStarted    keyDown → mic running (not part of the release-to-paste target)
  keyUp         recording length (not a latency)
  audioStopped  key release → recorder stopped
  vadDone       VAD gate
  sttDone       speech-to-text (for streaming Apple engines: final pass only)
  llmDone       clean-mode rewrite (stage 3)
  pasted        paste (stage 2)
  total_from_keyUp  key release → last stage: the number the targets refer to

Usage:
  python3 tools/latency_report.py                 # all records
  python3 tools/latency_report.py --last 30       # most recent 30
  python3 tools/latency_report.py --since 2026-11-20
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

DEFAULT = Path.home() / "Library/Application Support/SpeechToPrompt/history.jsonl"
STAGES = ["micStarted", "audioStopped", "vadDone", "sttDone", "llmDone", "pasted", "total_from_keyUp"]
TARGET_MS = {"raw": 1500, "clean": 4000}


def pct(values: list[float], p: float) -> float:
    s = sorted(values)
    k = (len(s) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("history", nargs="?", type=Path, default=DEFAULT)
    ap.add_argument("--last", type=int, help="only the most recent N records")
    ap.add_argument("--since", help="only records on/after this date (YYYY-MM-DD)")
    ap.add_argument("--include-skipped", action="store_true", help="include clips that produced no text")
    args = ap.parse_args()

    if not args.history.exists():
        raise SystemExit(f"{args.history} not found (dictate something first)")
    records = []
    for line in args.history.read_text(encoding="utf-8").splitlines():
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    if args.since:
        records = [r for r in records if r.get("timestamp", "") >= args.since]
    if not args.include_skipped:
        records = [r for r in records if r.get("finalText")]
    if args.last:
        records = records[-args.last:]
    if not records:
        raise SystemExit("no matching records")

    groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for r in records:
        groups[(r.get("mode", "?"), r.get("engine", "?"))].append(r)

    for (mode, engine), rs in sorted(groups.items()):
        audio = [r.get("audioSeconds", 0) for r in rs]
        print(f"\n## {mode} · {engine} · {len(rs)} dictations · audio median {pct(audio, 0.5):.1f} s (max {max(audio):.1f} s)")
        print("| stage | p50 ms | p90 ms | max ms |")
        print("|---|---|---|---|")
        for stage in STAGES:
            vals = [r["latencyMS"][stage] for r in rs if stage in r.get("latencyMS", {})]
            if vals:
                print(f"| {stage} | {pct(vals, 0.5):.0f} | {pct(vals, 0.9):.0f} | {max(vals):.0f} |")
        totals = [r["latencyMS"]["total_from_keyUp"] for r in rs if "total_from_keyUp" in r.get("latencyMS", {})]
        target = TARGET_MS.get(mode)
        if totals and target:
            within = sum(t <= target for t in totals)
            print(f"\nkey release → done: {within}/{len(totals)} within the {target} ms target")


if __name__ == "__main__":
    main()
