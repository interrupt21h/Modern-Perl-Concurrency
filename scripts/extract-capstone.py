#!/usr/bin/env python3
"""Extract whole functions from the canonical, formatted capstone."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
source = (root / "examples/36-processing-capstone.pl").read_text()
for name in ("finish", "deliver"):
    match = re.search(r"^sub " + name + r" \{\n.*?^\}\n", source, re.M | re.S)
    if not match:
        raise SystemExit(f"Missing capstone function: {name}")
    (root / f"snippets/capstone-{name}.pl").write_text(match.group())
