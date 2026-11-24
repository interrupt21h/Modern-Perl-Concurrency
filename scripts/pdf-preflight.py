#!/usr/bin/env python3
"""Fail publication for unresolved references, overflow or off-page text."""
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

pdf, log = map(Path, sys.argv[1:])
text = log.read_text(errors="replace")
bad = re.findall(r"^.*(?:Overfull \\[hv]box|There were undefined references|multiply defined|Label\(s\) may have changed|Rerun to get cross-references right).*$", text, re.M)
if bad:
    raise SystemExit("\n".join(bad))
xml = subprocess.check_output(["pdftotext", "-bbox", str(pdf), "-"])
root = ET.fromstring(xml)
pages = root.findall(".//{*}page")
if not pages:
    raise SystemExit("No PDF pages")
for i, page in enumerate(pages, 1):
    width = float(page.attrib["width"])
    height = float(page.attrib["height"])
    for word in page.findall("{*}word"):
        x0, y0, x1, y1 = (float(word.attrib[k]) for k in
            ("xMin", "yMin", "xMax", "yMax"))
        if min(x0, y0) < -1 or x1 > width + 1 or y1 > height + 1:
            raise SystemExit(f"{pdf}: off-page word on page {i}: {word.text}")
        if "\ufffd" in (word.text or ""):
            raise SystemExit(f"{pdf}: replacement glyph on page {i}")
print(f"PDF preflight: {pdf}, {len(pages)} pages, no unresolved references or off-page text")

# The index title must resolve to the physical index, not the previous chapter.
if pdf.name == "guide.pdf":
    import fitz
    with fitz.open(pdf) as doc:
        entries = [row for row in doc.get_toc() if row[1] == "Subject and API index"]
        if len(entries) != 1:
            raise SystemExit("Missing or duplicate index bookmark")
        destination = entries[0][2] - 1
        actual = [p.number for p in doc if any(35 < r.y0 < 180 and r.height > 14 for r in p.search_for("Subject and API index")) and p.number > len(doc) // 2]
        if actual != [destination]:
            raise SystemExit(f"Index bookmark points to {destination + 1}, actual pages {actual}")
        links = []
        for p in doc:
            if p.number == destination:
                continue
            for rect in p.search_for("Subject and API index"):
                links.extend(link for link in p.get_links() if link["from"].intersects(rect))
        if not links or any(link.get("page") != destination for link in links):
            raise SystemExit("Index contents link missing or points to wrong destination")
        print(f"Index navigation: bookmark and contents link point to page {destination + 1}")
