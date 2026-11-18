#!/usr/bin/env python3
"""List every word error per clip from a compare.py run, as compact text.

Useful for spotting patterns (e.g. one name always misheard) and deciding what to put in
config.json's "vocabulary".

Usage:
  eval/.venv/bin/python eval/errors.py                       # latest report
  eval/.venv/bin/python eval/errors.py eval/reports/X.json --engines whisper,apple-en-IN
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import metrics  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report", nargs="?", type=Path, help="a compare.py .json (default: newest in eval/reports)")
    ap.add_argument("--engines", help="comma-separated labels (default: all in the report)")
    ap.add_argument("--basic-normalizer", action="store_true")
    args = ap.parse_args()

    report = args.report
    if report is None:
        candidates = sorted((ROOT / "eval" / "reports").glob("*.json"))
        if not candidates:
            sys.exit("no reports in eval/reports; run compare.py first")
        report = candidates[-1]
    data = json.loads(report.read_text(encoding="utf-8"))
    labels = [l.strip() for l in args.engines.split(",")] if args.engines else list(data)
    use_whisper_norm = not args.basic_normalizer
    print(f"report: {report}\n")

    for label in labels:
        results = data.get(label)
        if not results:
            print(f"## {label}: not in report\n")
            continue
        misheard: Counter[str] = Counter()
        print(f"## {label}")
        for file in sorted(results):
            r = results[file]
            ref_path = Path(file).with_suffix(".txt")
            if not ref_path.is_absolute() and not ref_path.exists():
                ref_path = ROOT / ref_path  # report paths are relative to where compare.py ran
            ref = ref_path.read_text(encoding="utf-8").strip() if ref_path.exists() else ""
            if "error" in r:
                print(f"  {Path(file).stem}  ERROR {r['error']}")
                continue
            sc = metrics.score(ref, r.get("text", ""), use_whisper_norm)
            if sc.errors == 0:
                continue
            parts = []
            subs = [f"{o.ref}→{o.hyp}" for o in sc.ops if o.kind == "sub"]
            dels = [o.ref for o in sc.ops if o.kind == "del"]
            ins = [o.hyp for o in sc.ops if o.kind == "ins"]
            if subs:
                parts.append("heard " + ", ".join(subs))
            if dels:
                parts.append("DROPPED " + " ".join(dels))
            if ins:
                parts.append("INVENTED " + " ".join(ins))
            misheard.update(o.ref for o in sc.ops if o.kind in ("sub", "del"))
            tag = "silence/noise" if sc.ref_words == 0 else f"{sc.errors}/{sc.ref_words}"
            print(f"  {Path(file).stem} [{tag}]  " + " | ".join(parts))
        if misheard:
            common = ", ".join(f"{w}×{n}" for w, n in misheard.most_common(10))
            print(f"  most-missed reference words: {common}")
        print()


if __name__ == "__main__":
    main()
