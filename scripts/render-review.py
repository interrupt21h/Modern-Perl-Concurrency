#!/usr/bin/env python3
"""Render every page and provide HTML contact sheets for editorial review."""
import subprocess
import sys
from pathlib import Path

pdf = Path(sys.argv[1])
out = Path(sys.argv[2])
out.mkdir(exist_ok=True)
subprocess.run(
    ["pdftoppm", "-r", "96", "-png", str(pdf), str(out / "page")],
    check=True,
)
pages = sorted(out.glob("page-*.png"))
if not pages:
    raise SystemExit("No rendered pages")
for start in range(0, len(pages), 24):
    batch = pages[start:start+24]
    cells = "".join(
        f'<figure><a href="{p.name}"><img src="{p.name}"></a>'
        f'<figcaption>{p.stem}</figcaption></figure>' for p in batch
    )
    (out / f"contact-{start//24+1:02}.html").write_text(
        '<!doctype html><meta charset="utf-8"><title>PDF review</title>'
        '<style>body{font:14px system-ui;background:#eee}'
        'main{display:grid;grid-template-columns:repeat(4,1fr)}'
        'figure{margin:5px}img{width:100%;border:1px solid #aaa}</style>'
        f'<main>{cells}</main>', encoding="utf-8"
    )
print(f"Rendered {len(pages)} pages for visual inspection")
