"""Accuracy on real prose: this repository's Korean documents (README.md, CONTRIBUTING.md,
docs/url-run.md, docs/user-dictionary.md, .github/release-notes.md), Korean and English mixed
in sentences about software, with the previous word's language taken from the text itself.
The held-out set (make_eval.py) draws single words from subtitle frequency lists, so it misses
what gets typed at a keyboard like this one: technical loanwords, English names inside Korean
sentences, English with a Korean particle after it.

Tokens are runs of Hangul (Korean, typed back into 2-set keys and checked to round-trip),
of Latin letters (English, as written, capitals included) and Latin + Hangul (mixed: GitHub에).
Code spans, fenced blocks, URLs, link targets and tokens touching a digit are skipped. The
previous language is the label of the token before on the same line (the input method keeps
it across punctuation, and forgets it on a click or a focus change). A token is right when
the engine's output is the token as written.

usage: python3 eval_text.py <araso-cli> [--japanese] [--list [N]] <file.md> ...
"""
import re
import subprocess
import sys
from collections import Counter, defaultdict

from make_eval import keys_for

TOKEN = re.compile(r"[가-힣A-Za-z][가-힣A-Za-z']*")
HANGUL = re.compile(r"^[가-힣]+$")
LATIN = re.compile(r"^[A-Za-z][A-Za-z']*$")
MIXED = re.compile(r"^([A-Za-z][A-Za-z']*)([가-힣]+)$")
# The input method keeps the previous word's language across punctuation and forgets it on a
# click, a focus change or an arrow key: a line break stands for those here.
BOUNDARY = re.compile(r"\n")


def prose(text: str) -> str:
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"`[^`\n]*`", " ", text)
    text = re.sub(r"\]\([^)]*\)", "] ", text)          # link targets
    text = re.sub(r"https?://\S+|www\.\S+", " ", text)
    text = re.sub(r"<[^>\n]+>", " ", text)              # html tags
    return text


def tokens(text: str):
    """(token, label, keys, previous) for each token of the prose."""
    out = []
    last_end = 0
    previous = ""
    for m in TOKEN.finditer(text):
        token, start, end = m.group(), m.start(), m.end()
        gap = text[last_end:start]
        if BOUNDARY.search(gap):
            previous = ""
        last_end = end
        # a digit against the token (50k, 2-set, v0.3), or a dot joining it to another part
        # of a file or bundle name (README.en.md, com.apple.Safari)
        before = text[start - 1] if start > 0 else " "
        after = text[end] if end < len(text) else " "
        if before.isdigit() or after.isdigit():
            continue
        if (before == "." and start > 1 and text[start - 2].isalnum()) or (after == "." and end + 1 < len(text) and text[end + 1].isalpha()):
            continue
        if HANGUL.match(token):
            label, keys = "korean", keys_for(token)
        elif LATIN.match(token):
            label, keys = "english", token
        elif (mm := MIXED.match(token)):
            label, keys = "mixed", mm.group(1) + keys_for(mm.group(2))
        else:
            continue
        out.append((token, label, keys, previous))
        previous = "korean" if label == "mixed" else label
    return out


def compose(cli: str, keys: list[str]) -> dict[str, str]:
    res = subprocess.run([cli, "--compose"], input="\n".join(keys) + "\n", capture_output=True, text=True, check=True)
    return dict(line.split("\t", 1) for line in res.stdout.splitlines())


def main():
    args = sys.argv[1:]
    cli = args.pop(0)
    japanese = "--japanese" in args
    show = 0
    if "--list" in args:
        i = args.index("--list")
        show = int(args[i + 1]) if i + 1 < len(args) and args[i + 1].isdigit() else 40
    files = [a for a in args if a.endswith(".md")]
    rows = []
    for path in files:
        rows += tokens(prose(open(path, encoding="utf-8").read()))
    # Korean that doesn't round-trip through the composer (ㅢ typed as ㅡㅣ does; a typo wouldn't) is left out.
    hangul = compose(cli, sorted({k for _, label, k, _ in rows if label == "korean"}))
    rows = [r for r in rows if r[1] != "korean" or hangul.get(r[2]) == r[0]]

    cmd = [cli, "--decide"] + (["--japanese"] if japanese else [])
    res = subprocess.run(cmd, input="".join(f"{k}\t{p}\n" for _, _, k, p in rows), capture_output=True, text=True, check=True)
    out = [line.split("\t") for line in res.stdout.splitlines()]

    total, right = Counter(), Counter()
    by_prev_total, by_prev_right = Counter(), Counter()
    wrong = defaultdict(list)
    for (token, label, keys, previous), r in zip(rows, out):
        got = r[3]
        ok = got == token
        total[label] += 1
        by_prev_total[(label, previous or "-")] += 1
        if ok:
            right[label] += 1
            by_prev_right[(label, previous or "-")] += 1
        else:
            wrong[label].append((token, previous or "-", got, r[4]))
    n, k = sum(total.values()), sum(right.values())
    print(f"{'japanese on' if japanese else 'japanese off'}: {k}/{n} = {k / n:.4f}  ({len(files)} files)")
    for label in ("korean", "english", "mixed"):
        if not total[label]:
            continue
        cells = "  ".join(f"after {p:7} {by_prev_right[(label, p)]:5d}/{by_prev_total[(label, p)]:<5d}"
                          for p in ("-", "korean", "english") if by_prev_total[(label, p)])
        print(f"  {label:8} {right[label]:5d}/{total[label]:<5d} {right[label] / total[label]:.4f}   {cells}")
    if show:
        for label in ("korean", "english", "mixed"):
            misses = Counter((t, p, g) for t, p, g, _ in wrong[label])
            print(f"\n{label} wrong ({len(wrong[label])}, {len(misses)} distinct):")
            for (t, p, g), c in misses.most_common(show):
                expl = next(e for tt, pp, gg, e in wrong[label] if (tt, pp, gg) == (t, p, g))
                print(f"  {t:14} after {p:8} → {g:14} ×{c:<3} {expl[:60]}")


if __name__ == "__main__":
    main()
