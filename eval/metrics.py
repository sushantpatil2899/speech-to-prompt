"""Word-level alignment and error counts for comparing transcripts.

Terminology used in the reports:
  substitution  a reference word was transcribed as a different word
  deletion      a spoken word is missing from the transcript  ("dropped")
  insertion     the transcript has a word that was not spoken   ("invented")
  WER           (substitutions + deletions + insertions) / reference words
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

try:  # Whisper's English normalizer: numbers, spellings ("colour"→"color"), contractions...
    from whisper_normalizer.english import EnglishTextNormalizer  # type: ignore

    _whisper_norm = EnglishTextNormalizer()
except Exception:  # pragma: no cover - fallback when the package is missing
    _whisper_norm = None


def basic_normalize(text: str) -> str:
    """Lowercase, drop punctuation, collapse whitespace. Keeps apostrophes inside words."""
    text = unicodedata.normalize("NFKC", text).lower()
    text = re.sub(r"[‘’`´]", "'", text)
    text = re.sub(r"[^\w\s']", " ", text)
    text = re.sub(r"(?<!\w)'|'(?!\w)", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def normalize(text: str, use_whisper_normalizer: bool = True) -> str:
    if use_whisper_normalizer and _whisper_norm is not None:
        return re.sub(r"\s+", " ", _whisper_norm(text)).strip()
    return basic_normalize(text)


def normalizer_name() -> str:
    return "whisper EnglishTextNormalizer" if _whisper_norm is not None else "basic (whisper-normalizer not installed)"


@dataclass
class Op:
    kind: str  # "equal" | "sub" | "del" | "ins"
    ref: str | None
    hyp: str | None


@dataclass
class Score:
    ref_words: int
    hyp_words: int
    substitutions: int
    deletions: int
    insertions: int
    ops: list[Op] = field(default_factory=list)

    @property
    def errors(self) -> int:
        return self.substitutions + self.deletions + self.insertions

    @property
    def wer(self) -> float | None:
        return None if self.ref_words == 0 else self.errors / self.ref_words


def align(ref: list[str], hyp: list[str]) -> list[Op]:
    """Levenshtein alignment over words, with a backtrace.

    Ties prefer substitution, then deletion, then insertion, which gives the most
    readable diffs for transcripts.
    """
    n, m = len(ref), len(hyp)
    # cost[i][j] = edit distance between ref[:i] and hyp[:j]
    cost = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        cost[i][0] = i
    for j in range(1, m + 1):
        cost[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            same = ref[i - 1] == hyp[j - 1]
            cost[i][j] = min(
                cost[i - 1][j - 1] + (0 if same else 1),
                cost[i - 1][j] + 1,
                cost[i][j - 1] + 1,
            )

    ops: list[Op] = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and ref[i - 1] == hyp[j - 1] and cost[i][j] == cost[i - 1][j - 1]:
            ops.append(Op("equal", ref[i - 1], hyp[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and j > 0 and cost[i][j] == cost[i - 1][j - 1] + 1:
            ops.append(Op("sub", ref[i - 1], hyp[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and cost[i][j] == cost[i - 1][j] + 1:
            ops.append(Op("del", ref[i - 1], None))
            i -= 1
        else:
            ops.append(Op("ins", None, hyp[j - 1]))
            j -= 1
    ops.reverse()
    return ops


def merge_compounds(ref: list[str], hyp: list[str]) -> tuple[list[str], list[str]]:
    """Treat a word written split in one text and joined in the other as the same word.

    "stand up" vs "standup", "OOM killed" vs "OOMKilled", "log line" vs "logline" are spacing
    choices, not recognition errors, but plain WER counts each as two errors. Runs of 2-3
    words are joined when the joined form appears as a single word on the other side.
    """

    def join(tokens: list[str], targets: set[str]) -> list[str]:
        out, i = [], 0
        while i < len(tokens):
            for k in (3, 2):
                joined = "".join(tokens[i:i + k])
                if i + k <= len(tokens) and joined in targets:
                    out.append(joined)
                    i += k
                    break
            else:
                out.append(tokens[i])
                i += 1
        return out

    hyp = join(hyp, set(ref))
    ref = join(ref, set(hyp))
    return ref, hyp


def score(reference: str, hypothesis: str, use_whisper_normalizer: bool = True,
          compounds: bool = True) -> Score:
    ref = normalize(reference, use_whisper_normalizer).split()
    hyp = normalize(hypothesis, use_whisper_normalizer).split()
    if compounds:
        ref, hyp = merge_compounds(ref, hyp)
    ops = align(ref, hyp)
    return Score(
        ref_words=len(ref),
        hyp_words=len(hyp),
        substitutions=sum(o.kind == "sub" for o in ops),
        deletions=sum(o.kind == "del" for o in ops),
        insertions=sum(o.kind == "ins" for o in ops),
        ops=ops,
    )


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)
