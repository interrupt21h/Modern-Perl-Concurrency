#!/usr/bin/env python3
"""Protect the reviewed typography, illustration coverage and reading flow."""
from collections import Counter
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
def read(name):
    return (root / name).read_text()

guide = read("guide.tex")
code = read("styles/code-layout.tex")
visual = read("styles/handbook-visual-layout.tex")
shared = read("styles/quick-reference-diagrams.tex")
cheat = read("cheat-sheet.tex")
sources = "\n".join((guide, read("distributed-cache.tex"),
                     read("catalyst-sessions.tex"), visual))
required = [
    r"\documentclass[11pt,openany]{book}",
    r"\usepackage[letterpaper,margin=1.05in,headheight=15pt]{geometry}",
    r"\setstretch{1.12}",
    r"\setlength{\parskip}{8pt plus 1pt minus 1pt}",
    r"\titlespacing*{\section}{0pt}{19pt}{8pt}",
    r"\renewcommand{\arraystretch}{1.20}",
    r"left=11pt,right=11pt,top=9pt,bottom=10pt",
    r"\QRstrategyplain{#1}{#3}",
]
errors = [f"Missing reviewed layout setting: {s}" for s in required if s not in guide]
if "before skip=13pt,after skip=13pt" not in code or "enhanced,breakable" not in code:
    errors.append("Code box spacing or breakability changed")
if re.search(r"\\quick(?:fig|pair)\{", sources):
    errors.append("Independent quick-reference floats reintroduced")
if re.search(r"\\(?:resizebox|begin\{figure\})", visual):
    errors.append("Visual models must use max-size non-floating placement")
names = re.findall(r"\\newcommand\{\\(D[A-Za-z]+)\}", shared)
uses = Counter(re.findall(r"\\(D[A-Za-z]+)\b", sources))
if len(names) != 24 or any(uses[n] != 1 for n in names):
    errors.append("Expected all 24 artwork definitions exactly once in the handbook")
for name in names:
    if len(re.findall(r"\\QRstore\{\d+\}\{\\%s\}" % name, cheat)) != 1:
        errors.append(f"Cheat-sheet artwork coverage: {name}")
if errors:
    raise SystemExit("\n".join(errors))
print("Layout contract: typography, code style, non-floating visual models and 24 artwork references passed")
