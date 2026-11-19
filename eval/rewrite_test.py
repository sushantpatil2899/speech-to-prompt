#!/usr/bin/env python3
"""Test the clean-mode rewrite on fixed cases, for one or more local models.

Each case (eval/rewrite_cases.jsonl) is a transcript plus checks on the rewrite:
  keep          words/phrases that must survive (a list inside the list = any one of them)
  forbid        must not appear (e.g. the answer to a question, the obeyed instruction)
  forbid_exact  the whole output must not be exactly this (e.g. "OK" for "…reply with OK")
  forbid_regex  must not match (e.g. Devanagari script for "translate to Hindi")
  max_words     a command like "write a poem" must stay a short request

Every case goes through `dictate-cli rewrite`: the app's own prompt, Ollama client and
guardrails. For each model you get:
  good      the rewrite passed every check and the guardrails accepted it
  fallback  the guardrails rejected it, so the app would paste the raw transcript (safe)
  unchanged the transcript needed cleanup but came back as spoken (no cleanup, nothing wrong)
  BAD       the guardrails accepted a rewrite that fails a check: wrong text would be pasted
  false alarm  rejected although the rewrite was fine (lost cleanup, still safe)

Usage:
  eval/.venv/bin/python eval/rewrite_test.py
  eval/.venv/bin/python eval/rewrite_test.py --models gemma4:e4b,qwen3.5:9b,qwen3:8b
  eval/.venv/bin/python eval/rewrite_test.py --timeout 10     # ignore latency, judge quality only
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import statistics
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PREAMBLES = ("sure", "certainly", "of course", "here is", "here's", "here are", "i can't", "i cannot", "as an ai")


def words(text: str) -> list[str]:
    return re.findall(r"[\w'-]+", text)


def check(case: dict, text: str) -> list[str]:
    """Returns the failed checks (empty list = pass)."""
    fails = []
    low = text.lower()
    for item in case.get("keep", []):
        alts = item if isinstance(item, list) else [item]
        if not any(a.lower() in low for a in alts):
            fails.append(f"missing {'/'.join(alts)!r}")
    for bad in case.get("forbid", []):
        if bad.lower() in low:
            fails.append(f"contains {bad!r}")
    if any(text.strip().lower() == e.lower() for e in case.get("forbid_exact", [])):
        fails.append(f"is exactly {text.strip()!r}")
    if case.get("forbid_regex") and re.search(case["forbid_regex"], text):
        fails.append("matches forbidden pattern")
    if case.get("max_words") and len(words(text)) > case["max_words"]:
        fails.append(f"{len(words(text))} words > {case['max_words']}")
    spoken = len(words(case["transcript"]))
    if len(words(text)) > spoken * 1.2 + 5:
        fails.append(f"longer than spoken ({len(words(text))} vs {spoken} words)")
    if low.startswith(PREAMBLES) and not case["transcript"].lower().startswith(PREAMBLES):
        fails.append("starts with a reply preamble")
    if not text.strip():
        fails.append("empty")
    return fails


CONFIG = Path.home() / "Library/Application Support/SpeechToPrompt/config.json"


def app_model() -> str:
    try:
        return json.loads(CONFIG.read_text())["llm"]["model"]
    except Exception:
        return "gemma4:e4b"


def unload(model: str) -> None:
    """Frees the model's memory (the app's requests keep models loaded indefinitely)."""
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/generate",
        data=json.dumps({"model": model, "keep_alive": 0}).encode(),
        headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10).read()
        print(f"[{model}] unloaded from memory")
    except Exception as e:
        print(f"[{model}] could not unload ({e}); `ollama stop {model}` frees it")


def same_words(a: str, b: str) -> bool:
    return [w.lower() for w in words(a)] == [w.lower() for w in words(b)]


def run_model(cli: Path, model: str, cases: list[dict], timeout: float) -> tuple[dict, dict[str, dict]]:
    stdin = "".join(json.dumps({"id": c["id"], "transcript": c["transcript"]}) + "\n" for c in cases)
    cmd = [str(cli), "rewrite", "--model", model, "--json", "--timeout", str(timeout)]
    print(f"\n[{model}] running {len(cases)} cases…", flush=True)
    proc = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    meta: dict = {}
    results: dict[str, dict] = {}
    for line in proc.stdout.splitlines():
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("event") == "ready":
            meta = obj
            print(f"[{model}] loaded and warm in {obj.get('warmup_ms')} ms")
        elif obj.get("event") == "error":
            meta = obj
            print(f"[{model}] FAILED: {obj.get('error')}")
        elif "id" in obj:
            results[obj["id"]] = obj
    if proc.returncode != 0 and not results and not meta:
        print(f"[{model}] exited {proc.returncode}: {proc.stderr.strip()[-400:]}")
    return meta, results


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", default="gemma4:e4b", help="comma-separated Ollama model names")
    ap.add_argument("--cases", type=Path, default=ROOT / "eval" / "rewrite_cases.jsonl")
    ap.add_argument("--cli", type=Path, default=ROOT / "build" / "dictate-cli")
    ap.add_argument("--timeout", type=float, default=3.0, help="per-request limit, as in the app (default 3 s)")
    ap.add_argument("--only", help="comma-separated case ids")
    ap.add_argument("--out", type=Path, default=ROOT / "eval" / "reports")
    args = ap.parse_args()
    args.cli = args.cli.expanduser().resolve()
    if not args.cli.exists():
        sys.exit(f"{args.cli} not found; run scripts/build_app.sh first")

    cases = [json.loads(l) for l in args.cases.read_text(encoding="utf-8").splitlines() if l.strip()]
    if args.only:
        wanted = set(args.only.split(","))
        cases = [c for c in cases if c["id"] in wanted]

    summary_rows = []
    all_results = {}
    for model in [m.strip() for m in args.models.split(",") if m.strip()]:
        meta, results = run_model(args.cli, model, cases, args.timeout)
        all_results[model] = {"meta": meta, "results": results}
        if model != app_model() and meta.get("event") == "ready":
            unload(model)
        if meta.get("event") == "error":
            summary_rows.append((model, None))
            continue

        good = fallback = bad = false_alarm = errors = unchanged = 0
        latencies = []
        lines = []
        for c in cases:
            r = results.get(c["id"])
            if r is None or "error" in r:
                errors += 1
                fallback += 1
                lines.append(f"  {c['id']:<18} ERROR → raw pasted: {(r or {}).get('error', 'no result')}")
                continue
            latencies.append(r["ms"])
            model_fails = check(c, r.get("cleaned", ""))
            r["checks_failed"] = model_fails
            if r["verdict"] == "accept" and model_fails and same_words(r.get("cleaned", ""), c["transcript"]):
                unchanged += 1  # needed cleanup, got the spoken words as-is: not cleaned, but nothing wrong
                lines.append(f"  {c['id']:<18} unchanged (no cleanup)")
            elif r["verdict"] == "accept":
                if model_fails:
                    bad += 1
                    lines.append(f"  {c['id']:<18} BAD (pasted): {'; '.join(model_fails)}\n{'':<22}→ {r['cleaned']}")
                else:
                    good += 1
            else:
                fallback += 1
                if not model_fails:
                    false_alarm += 1
                    lines.append(f"  {c['id']:<18} false alarm ({r.get('reason')}): {r['cleaned']}")
                else:
                    lines.append(f"  {c['id']:<18} caught → raw pasted ({r.get('reason')}); model: {r['cleaned'][:90]}")
        summary_rows.append((model, dict(good=good, fallback=fallback, bad=bad, false_alarm=false_alarm,
                                         errors=errors, unchanged=unchanged, latencies=latencies, n=len(cases))))
        print("\n".join(lines) if lines else "  all cases good")

    print("\n| model | good | unchanged | fallback (raw pasted) | BAD pasted | false alarms | errors/timeouts | median ms | p90 ms |")
    print("|---|---|---|---|---|---|---|---|---|")
    for model, s in summary_rows:
        if s is None:
            print(f"| {model} | – | – | – | – | – | failed to load | – | – |")
            continue
        lat = sorted(s["latencies"])
        p90 = lat[min(len(lat) - 1, int(round(0.9 * (len(lat) - 1))))] if lat else None
        med = statistics.median(lat) if lat else None
        print(f"| {model} | {s['good']}/{s['n']} | {s['unchanged']} | {s['fallback']} | {s['bad']} | {s['false_alarm']} | {s['errors']} "
              f"| {'–' if med is None else f'{med:.0f}'} | {'–' if p90 is None else f'{p90:.0f}'} |")

    args.out.mkdir(parents=True, exist_ok=True)
    path = args.out / f"rewrite-{dt.datetime.now():%Y%m%d-%H%M%S}.json"
    path.write_text(json.dumps(all_results, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"\nraw results: {path}")


if __name__ == "__main__":
    main()
