#!/usr/bin/env python3
"""Produce editorial review candidates from rendered page geometry; not a visual sign-off."""
import json
import sys
from pathlib import Path
import fitz

pdf, output = map(Path, sys.argv[1:])
records = []
with fitz.open(pdf) as doc:
    for page in doc:
        body = fitz.Rect(70, 70, page.rect.width - 70, page.rect.height - 70)
        # Rasterized vertical occupancy includes vector shapes, unlike text-only bounds.
        pix = page.get_pixmap(matrix=fitz.Matrix(1, 1), clip=body,
                              colorspace=fitz.csGRAY, alpha=False)
        samples = pix.samples
        rows = [y for y in range(pix.height)
                if sum(v < 215 for v in samples[y*pix.stride:y*pix.stride+pix.width]) >= 3]
        occupancy = round(len(rows) / max(pix.height, 1), 3)
        text = page.get_text("text", clip=body)
        kind = "front/part" if page.number < 3 or text.lstrip().startswith("PART ") else "body"
        records.append(dict(page=page.number+1, kind=kind,
                            occupied_row_fraction=occupancy,
                            visual_models=text.count("Visual model"),
                            review=(kind=="body" and occupancy < .20)))
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(records, indent=2)+"\n")
flags = [str(x["page"]) for x in records if x["review"]]
print(f"Handbook layout: {len(records)} pages; sparse-page review candidates: {', '.join(flags) or 'none'}")
print("Candidates require editorial inspection; intended whitespace is not an error.")
