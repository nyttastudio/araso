"""Norwegian (bokmål) words with how common they are, for Norwegian on (Settings.norwegian):
Data/norwegian_words.txt, which EnglishModel's Norwegian model reads next to english_words.txt.

From the OpenSubtitles frequency list of hermitdave/FrequencyWords (no_full.txt, CC BY-SA 4.0):
a word's rank becomes a SCOWL-like level, 10 (the most common) to 60. Letters a–z, æ, ø, å only,
lowercased; one-letter words only when listed in SHORT.

usage: python3 build_norwegian_words.py <no_full.txt> <out.txt>
Output: word<TAB>level, sorted by level then word.
"""
import re
import sys

no_path, out_path = sys.argv[1:3]
WORD = re.compile(r"^[a-zæøå]+$")
SHORT = {"i", "å", "e"}  # e: the letter name; i, å are words
RANKS = [(1500, 10), (4000, 20), (10000, 35), (25000, 40), (50000, 50), (120000, 60)]
MIN_COUNT = 5

level: dict[str, int] = {}
rank = 0
for line in open(no_path, encoding="utf-8"):
    parts = line.split()
    if len(parts) != 2:
        continue
    w, count = parts[0].lower(), int(parts[1])
    if not WORD.match(w) or (len(w) == 1 and w not in SHORT):
        continue
    rank += 1
    if count < MIN_COUNT:
        break
    for limit, lv in RANKS:
        if rank <= limit:
            level[w] = min(level.get(w, 99), lv)
            break
with open(out_path, "w", encoding="utf-8") as out:
    for w, lv in sorted(level.items(), key=lambda kv: (kv[1], kv[0])):
        out.write(f"{w}\t{lv}\n")
print(f"{len(level)} Norwegian words")
