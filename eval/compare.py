#!/usr/bin/env python3
"""Run the same recorded clips through several speech engines and compare them.

Each clip is DIR/NNN.wav with its reference transcript in DIR/NNN.txt
(an empty .txt means the clip should produce no text: silence or noise).

For every engine it reports:
  - WER, and separately substitutions, DROPPED words (deletions) and INVENTED words (insertions)
  - hallucinations: any output on silence/noise clips
  - latency per clip (engine time after the VAD gate) and real-time factor

Engines run through `dictate-cli transcribe`, the same code path as the app (same VAD
gate, decoding settings and cleanup). mlx-whisper runs in-process for comparison and
gets the same VAD decision and trimmed audio.

Usage:
  eval/.venv/bin/python eval/compare.py eval/clips
  eval/.venv/bin/python eval/compare.py eval/clips --engines whisper,apple-en-IN
  eval/.venv/bin/python eval/compare.py eval/clips --no-vad      # see raw hallucination behaviour
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import statistics
import subprocess
import sys
import time
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import metrics  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

# label -> dictate-cli arguments (None = in-process engine)
ENGINES: dict[str, list[str] | None] = {
    "whisper": ["--engine", "whisper"],
    "whisper-beam5": ["--engine", "whisper", "--beam", "5"],
    "whisper-nofallback": ["--engine", "whisper", "--no-fallback"],
    "apple-en-IN": ["--engine", "apple", "--locale", "en-IN"],
    "apple-en-US": ["--engine", "apple", "--locale", "en-US"],
    "apple-en-GB": ["--engine", "apple", "--locale", "en-GB"],
    "dictation-en-IN": ["--engine", "apple-dictation", "--locale", "en-IN"],
    "dictation-en-US": ["--engine", "apple-dictation", "--locale", "en-US"],
    "mlx-whisper": None,
}
DEFAULT_ENGINES = "whisper,apple-en-IN,apple-en-US,dictation-en-IN,mlx-whisper"


def find_clips(directory: Path) -> list[tuple[Path, str]]:
    clips = []
    for wav in sorted(directory.glob("*.wav")):
        txt = wav.with_suffix(".txt")
        if not txt.exists():
            print(f"warning: {wav.name} has no {txt.name}; skipped", file=sys.stderr)
            continue
        clips.append((wav, txt.read_text(encoding="utf-8").strip()))
    return clips


def run_cli(cli: Path, label: str, args: list[str], files: list[Path], extra: list[str]) -> dict[str, dict]:
    cmd = [str(cli), "transcribe", *args, *extra, "--json", *map(str, files)]
    print(f"\n[{label}] {' '.join(cmd[:6])} … ({len(files)} clips)", flush=True)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    results: dict[str, dict] = {}
    for line in proc.stdout.splitlines():
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("event") == "ready":
            print(f"[{label}] {obj.get('engine')} ready in {obj.get('prepare_ms')} ms (VAD {obj.get('vad')})")
        elif obj.get("event") == "error":
            print(f"[{label}] FAILED: {obj.get('error')}")
        elif "file" in obj:
            results[obj["file"]] = obj
    if proc.returncode != 0 and not results:
        print(f"[{label}] exited with {proc.returncode}: {proc.stderr.strip()[-500:]}")
    return results


def read_wav_16k(path: Path):
    import numpy as np

    with wave.open(str(path), "rb") as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise ValueError(f"{path.name}: expected 16 kHz mono 16-bit WAV (dictate-cli record makes these)")
        data = w.readframes(w.getnframes())
    return np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0


def run_mlx(files: list[Path], gate: dict[str, dict], model: str, vocab: list[str]) -> dict[str, dict]:
    print(f"\n[mlx-whisper] {model}", flush=True)
    try:
        import mlx_whisper  # type: ignore
        import numpy as np
    except ImportError:
        print("[mlx-whisper] not installed (pip install mlx-whisper); skipped")
        return {}
    prompt = ("Glossary: " + ", ".join(vocab) + ".") if vocab else None
    options = dict(path_or_hf_repo=model, language="en", condition_on_previous_text=False, initial_prompt=prompt, verbose=None)
    t0 = time.perf_counter()
    mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), **options)  # load + warm up
    print(f"[mlx-whisper] ready in {int((time.perf_counter() - t0) * 1000)} ms")

    results = {}
    for f in files:
        key = str(f)
        audio = read_wav_16k(f)
        g = gate.get(key, {})
        obj = {"file": key, "engine": f"mlx-whisper/{model.split('/')[-1]}", "audio_s": len(audio) / 16000}
        if g.get("skipped"):
            obj.update(text="", skipped=True, stt_ms=0, note="skipped by VAD gate (same decision as dictate-cli)")
        else:
            if "trim_start_s" in g:
                audio = audio[int(g["trim_start_s"] * 16000): int(g["trim_end_s"] * 16000)]
            t = time.perf_counter()
            out = mlx_whisper.transcribe(audio, **options)
            obj.update(text=out.get("text", "").strip(), skipped=False, stt_ms=(time.perf_counter() - t) * 1000)
        results[key] = obj
    return results


def summarize(label: str, clips, results: dict[str, dict], whisper_norm: bool) -> dict:
    s = dict(label=label, engine=None, clips=0, ref_words=0, sub=0, dele=0, ins=0,
             silent_clips=0, silent_halluc=0, errors=0, latencies=[], audio_s=0.0, stt_s=0.0)
    for wav, ref in clips:
        r = results.get(str(wav))
        if r is None or "error" in r:
            s["errors"] += 1
            continue
        s["engine"] = s["engine"] or r.get("engine")
        sc = metrics.score(ref, r.get("text", ""), whisper_norm)
        r["score"] = sc
        s["clips"] += 1
        if sc.ref_words == 0:
            s["silent_clips"] += 1
            s["silent_halluc"] += 1 if sc.hyp_words > 0 else 0
        else:
            s["ref_words"] += sc.ref_words
            s["sub"] += sc.substitutions
            s["dele"] += sc.deletions
            s["ins"] += sc.insertions
            if not r.get("skipped"):
                s["latencies"].append(r.get("stt_ms", 0))
                s["audio_s"] += r.get("audio_s", 0)
                s["stt_s"] += r.get("stt_ms", 0) / 1000
    s["wer"] = (s["sub"] + s["dele"] + s["ins"]) / s["ref_words"] if s["ref_words"] else None
    return s


def fmt_pct(x):
    return "–" if x is None else f"{x * 100:.1f}%"


def fmt_ms(x):
    return "–" if x is None else f"{x:.0f}"


def markdown_summary(summaries) -> str:
    rows = ["| engine | clips | WER | substituted | dropped | invented | output on silence/noise | median ms | p90 ms | RTF |",
            "|---|---|---|---|---|---|---|---|---|---|"]
    for s in summaries:
        lat = s["latencies"]
        rtf = s["stt_s"] / s["audio_s"] if s["audio_s"] else None
        rows.append(
            f"| {s['label']} | {s['clips']}{' (' + str(s['errors']) + ' failed)' if s['errors'] else ''} | {fmt_pct(s['wer'])} "
            f"| {s['sub']} | {s['dele']} | {s['ins']} | {s['silent_halluc']}/{s['silent_clips']} "
            f"| {fmt_ms(statistics.median(lat) if lat else None)} | {fmt_ms(metrics.percentile(lat, 0.9))} "
            f"| {'–' if rtf is None else f'{rtf:.3f}'} |")
    return "\n".join(rows)


def diff_html(score: metrics.Score) -> str:
    out = []
    for op in score.ops:
        if op.kind == "equal":
            out.append(html.escape(op.hyp))
        elif op.kind == "sub":
            out.append(f'<span class="sub" title="said: {html.escape(op.ref)}"><s>{html.escape(op.ref)}</s>→{html.escape(op.hyp)}</span>')
        elif op.kind == "del":
            out.append(f'<span class="del" title="dropped">{html.escape(op.ref)}</span>')
        else:
            out.append(f'<span class="ins" title="invented">{html.escape(op.hyp)}</span>')
    return " ".join(out) or '<span class="none">(no output)</span>'


def write_html(path: Path, clips, all_results, summaries, args, normalizer: str):
    def summary_table():
        head = "".join(f"<th>{h}</th>" for h in ["engine", "clips", "WER", "substituted", "dropped", "invented",
                                                   "output on silence/noise", "median ms", "p90 ms", "RTF"])
        body = []
        for s in summaries:
            lat = s["latencies"]
            rtf = s["stt_s"] / s["audio_s"] if s["audio_s"] else None
            body.append("<tr>" + "".join(f"<td>{c}</td>" for c in [
                f"<b>{html.escape(s['label'])}</b><br><small>{html.escape(s['engine'] or '')}</small>",
                s["clips"], fmt_pct(s["wer"]), s["sub"], f'<span class="delc">{s["dele"]}</span>',
                f'<span class="insc">{s["ins"]}</span>', f"{s['silent_halluc']}/{s['silent_clips']}",
                fmt_ms(statistics.median(lat) if lat else None), fmt_ms(metrics.percentile(lat, 0.9)),
                "–" if rtf is None else f"{rtf:.3f}"]) + "</tr>")
        return f"<table><thead><tr>{head}</tr></thead><tbody>{''.join(body)}</tbody></table>"

    sections = []
    for wav, ref in clips:
        rows = []
        for s in summaries:
            r = all_results[s["label"]].get(str(wav))
            if r is None or "error" in r:
                rows.append(f"<tr><th>{html.escape(s['label'])}</th><td class='none'>error: {html.escape(str((r or {}).get('error', 'no result')))}</td><td></td></tr>")
                continue
            sc = r["score"]
            stats = f"{sc.substitutions}S {sc.deletions}D {sc.insertions}I"
            if r.get("skipped"):
                stats += " · VAD skip"
            elif "stt_ms" in r:
                stats += f" · {r['stt_ms']:.0f} ms"
            rows.append(f"<tr><th>{html.escape(s['label'])}</th><td>{diff_html(sc)}</td><td class='stats'>{stats}</td></tr>")
        ref_html = html.escape(ref) if ref else "<i>(silence/noise: expected no output)</i>"
        sections.append(f"<section><h3>{html.escape(wav.name)}</h3><p class='ref'><b>Said:</b> {ref_html}</p>"
                        f"<table class='clip'>{''.join(rows)}</table></section>")

    page = f"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Engine comparison</title><style>
:root {{ --bg:#fff; --fg:#1d1d1f; --muted:#6e6e73; --line:#e5e5ea; --del:#c62828; --ins:#1b7f3b; --sub:#b25e00; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#1c1c1e; --fg:#f2f2f7; --muted:#a1a1a6; --line:#3a3a3c; --del:#ff6b6b; --ins:#5bd77d; --sub:#ffb454; }} }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system,system-ui,sans-serif; margin:24px auto; max-width:1100px; padding:0 16px; }}
table {{ border-collapse:collapse; width:100%; margin:8px 0 24px; }}
th,td {{ border-bottom:1px solid var(--line); padding:6px 8px; text-align:left; vertical-align:top; }}
table.clip th {{ width:150px; font-weight:600; }}
.stats {{ white-space:nowrap; color:var(--muted); font-size:13px; }}
.del {{ color:var(--del); text-decoration:line-through; font-weight:600; }}
.ins {{ color:var(--ins); text-decoration:underline; font-weight:600; }}
.delc {{ color:var(--del); font-weight:600; }} .insc {{ color:var(--ins); font-weight:600; }}
.sub {{ color:var(--sub); font-weight:600; }} .sub s {{ opacity:.7; }}
.none {{ color:var(--muted); font-style:italic; }} .ref {{ margin:4px 0; }} small {{ color:var(--muted); }}
section {{ margin-top:18px; }} h3 {{ margin:0; font-size:15px; }}
</style></head><body>
<h1>Speech engine comparison</h1>
<p>{dt.datetime.now():%Y-%m-%d %H:%M} · {len(clips)} clips from <code>{html.escape(str(args.clips))}</code> · VAD {'off' if args.no_vad else 'on'} · normalizer: {html.escape(normalizer)}</p>
<p>Legend: <span class="del">dropped</span> (spoken, missing) · <span class="ins">invented</span> (not spoken) · <span class="sub"><s>said</s>→heard</span> (substituted). Latency is engine time after the VAD gate; the Apple engines stream in the app, so their in-app latency after key release is lower than shown here.</p>
{summary_table()}
<h2>Per clip</h2>
{''.join(sections)}
</body></html>"""
    path.write_text(page, encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clips", type=Path, help="directory with NNN.wav + NNN.txt pairs")
    ap.add_argument("--engines", default=DEFAULT_ENGINES, help=f"comma-separated, from: {', '.join(ENGINES)}")
    ap.add_argument("--cli", type=Path, default=ROOT / "build" / "dictate-cli")
    ap.add_argument("--mlx-model", default="mlx-community/whisper-large-v3-turbo")
    ap.add_argument("--vocab", default="", help="comma-separated vocabulary hint passed to every engine")
    ap.add_argument("--no-vad", action="store_true", help="disable the VAD gate")
    ap.add_argument("--basic-normalizer", action="store_true", help="lowercase/punctuation only, instead of Whisper's normalizer")
    ap.add_argument("--out", type=Path, default=ROOT / "eval" / "reports")
    args = ap.parse_args()
    args.cli = args.cli.expanduser().resolve()

    clips = find_clips(args.clips)
    if not clips:
        sys.exit(f"no clips in {args.clips} (record some with: build/dictate-cli record --prompts eval/prompts.txt --out {args.clips})")
    labels = [e.strip() for e in args.engines.split(",") if e.strip()]
    unknown = [e for e in labels if e not in ENGINES]
    if unknown:
        sys.exit(f"unknown engine(s): {', '.join(unknown)}")
    if any(ENGINES[l] is not None for l in labels) and not os.access(args.cli, os.X_OK):
        sys.exit(f"{args.cli} not found; run scripts/build_app.sh first")

    files = [w for w, _ in clips]
    vocab = [v.strip() for v in args.vocab.split(",") if v.strip()]
    extra = (["--no-vad"] if args.no_vad else []) + (["--vocab", ",".join(vocab)] if vocab else [])

    all_results: dict[str, dict[str, dict]] = {}
    for label in labels:
        if ENGINES[label] is not None:
            all_results[label] = run_cli(args.cli, label, ENGINES[label], files, extra)

    if "mlx-whisper" in labels:
        # Reuse the VAD decision from a dictate-cli run so mlx-whisper sees the same audio.
        gate = next((r for r in all_results.values() if r), None)
        if gate is None:
            gate = run_cli(args.cli, "vad-gate", ENGINES["whisper"], files, extra) if os.access(args.cli, os.X_OK) else {}
        all_results["mlx-whisper"] = run_mlx(files, {} if args.no_vad else gate, args.mlx_model, vocab)

    whisper_norm = not args.basic_normalizer
    normalizer = metrics.normalizer_name() if whisper_norm else "basic"
    # Engines that produced nothing at all and aren't dictate-cli engines (mlx not installed) are left out.
    summaries = [summarize(l, clips, all_results[l], whisper_norm) for l in labels
                 if l in all_results and (all_results[l] or ENGINES[l] is not None)]

    args.out.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    html_path = args.out / f"{stamp}.html"
    write_html(html_path, clips, all_results, summaries, args, normalizer)
    json_path = args.out / f"{stamp}.json"
    json_path.write_text(json.dumps(
        {label: {k: {kk: vv for kk, vv in v.items() if kk != "score"} for k, v in res.items()}
         for label, res in all_results.items()}, indent=1), encoding="utf-8")

    print("\n" + markdown_summary(summaries))
    print(f"\nnormalizer: {normalizer}")
    print(f"report: {html_path}\nraw results: {json_path}")


if __name__ == "__main__":
    main()
