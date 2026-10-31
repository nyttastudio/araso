"""English acronyms, for telling an acronym + particle from Korean typed with Shift held on.

From SCOWL (see build_english_words.py): every entry of two or more capitals and nothing else
(RNA, GMT, WYSIWYG) in the abbreviation and capitalized-word lists up to `max_level`.

usage: python3 build_english_acronyms.py <scowl>/final <out.txt> [max_level=70]
Output: one acronym per line, sorted.
"""
import re
import sys
from pathlib import Path

final, out_path = Path(sys.argv[1]), sys.argv[2]
max_level = int(sys.argv[3]) if len(sys.argv) > 3 else 70
ACRONYM = re.compile(r"^[A-Z]{2,}$")
acronyms: set[str] = set()
for path in final.iterdir():
    m = re.match(r"^(english|american)-(abbreviations|upper)\.(\d+)$", path.name)
    if not m or int(m.group(3)) > max_level:
        continue
    for line in path.read_text(encoding="latin-1").splitlines():
        if ACRONYM.match(line.strip()):
            acronyms.add(line.strip())
with open(out_path, "w", encoding="utf-8") as out:
    out.writelines(f"{a}\n" for a in sorted(acronyms))
print(f"{len(acronyms)} acronyms")
