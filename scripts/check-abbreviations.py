#!/usr/bin/env python3
"""Check glossary coverage and report chapter/figure abbreviation candidates."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
guide = (root / "guide.tex").read_text()
glossary = guide.split(r"\section*{Abbreviations and initialisms}", 1)[1].split(r"\end{longtable}", 1)[0]
known = set()
for line in glossary.splitlines():
    if " & " in line:
        known.update(line.split(" & ", 1)[0].split(" / "))
required = set("API CAS CI CPU CSRF CSPRNG DBI HTTP HTTPS IPC JSON JWT MVCC PID SQL TLS TTL UUID WAL".split())
missing = required - known
if missing:
    sys.exit("Missing glossary entries: " + ", ".join(sorted(missing)))
paths = [root / "guide.tex", *sorted((root / "chapters").glob("*.tex")),
         *sorted((root / "figures").glob("*.tex")),
         *(root / p for p in ("distributed-cache.tex", "catalyst-sessions.tex", "api-credentials.tex"))]
for path in paths:
    source = path.read_text()
    source = re.sub(r"(?m)(?<!\\)%.*$", "", source)
    source = re.sub(r"\\(?:CodeFile|input|label|ref|cite|url|nolinkurl)\{[^{}\n]*\}", "", source)
    candidates = set(re.findall(r"\b[A-Z][A-Z0-9-]{1,}\b", source))
    unknown = sorted(candidates - known)
    if unknown:
        print(f"{path.relative_to(root)}: review candidates: {', '.join(unknown)}")
print(f"Glossary coverage passed ({len(known)} entries); candidates require editorial review.")
