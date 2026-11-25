#!/usr/bin/env python3
"""Publish every verified PDF page in a linked, searchable HTML chapter reader.

The PDF is canonical for layout. SVG preserves TikZ, typefaces, code colours
and tables; a selectable HTML text layer and a reflowable transcript provide
browser-native text access. This is not a semantic conversion of the TeX.
"""
import argparse
import hashlib
import html
import json
import re
import shutil
from pathlib import Path
from urllib.parse import urlsplit

import fitz

esc = html.escape
TOP = re.compile(r"^(?:part|chapter|appendix)\*?\.")
NUMBERED = re.compile(r"^(chapter|appendix|part)\.([A-Za-z0-9]+)$")

CSS = """
:root{color-scheme:light dark;--bg:#f4f7fa;--paper:#fff;--ink:#172b3b;--muted:#526776;--accent:#08665f;--line:#d6e0e5}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.65 system-ui,sans-serif}
a{color:var(--accent);text-underline-offset:3px}a:focus-visible,button:focus-visible{outline:3px solid #c69242;outline-offset:3px}
.wrap{max-width:1000px;margin:auto;padding:1rem clamp(.75rem,3vw,2rem)}
header{background:#142c40;color:#fff}header a{color:#b3ece1}h1{font-size:clamp(1.65rem,4vw,2.7rem);line-height:1.15;margin:.5rem 0}
h2{line-height:1.25}nav{display:flex;gap:1rem;flex-wrap:wrap;align-items:center}small,.muted{color:var(--muted)}
header small{color:#dae5ef}.eyebrow{text-transform:uppercase;letter-spacing:.12em;font-size:.78rem;font-weight:700}
.panel{background:var(--paper);border:1px solid var(--line);border-radius:9px;padding:1rem 1.25rem;margin:1rem 0}
button{font:inherit;cursor:pointer;color:var(--ink);background:var(--paper);border:1px solid var(--line);border-radius:6px;padding:.4rem .8rem}
button[aria-pressed=true]{border:2px solid var(--accent);font-weight:700}
.reading-page{margin:1.3rem auto;max-width:850px;scroll-margin-top:1rem}
.page-label{display:flex;justify-content:space-between;gap:1rem;margin-bottom:.25rem;font-size:.85rem}
.sheet{position:relative;width:100%;container-type:inline-size;background:white;box-shadow:0 2px 12px #0002;overflow:hidden}
.sheet>img{display:block;width:100%;height:auto}
.text-layer{position:absolute;inset:0;color:transparent;line-height:1;overflow:hidden;user-select:text}
.text-layer span{position:absolute;white-space:pre;transform-origin:left top}
.text-layer ::selection{color:transparent;background:#55a8e266}
.pdf-link{position:absolute;display:block}.pdf-link:focus-visible{outline:2px solid #007f83;outline-offset:0;background:#007f8322}
.transcript{background:var(--paper);padding:1rem;border:1px solid var(--line);border-radius:6px}
.transcript pre{font:inherit;white-space:pre-wrap;overflow-wrap:anywhere;margin:0}
[hidden]{display:none!important}li{margin:.3rem 0}footer{border-top:1px solid var(--line)}
@media(prefers-color-scheme:dark){:root{--bg:#111a22;--paper:#192633;--ink:#e7eef5;--muted:#aebfcc;--accent:#9be1d4;--line:#344653}}
@media print{header,footer,.controls,.page-label,.section-nav{display:none}.reading-page{break-after:page;margin:0}.sheet{box-shadow:none}.wrap{max-width:none;padding:0}}
"""

JS = """
const buttons = [...document.querySelectorAll('[data-mode]')];
function setMode(mode) {
  document.querySelectorAll('.sheet').forEach(node => node.hidden = mode === 'text');
  document.querySelectorAll('.transcript').forEach(node => node.hidden = mode !== 'text');
  buttons.forEach(node => node.setAttribute('aria-pressed', String(node.dataset.mode === mode)));
  if (mode === 'layout') requestAnimationFrame(fitText);
}
function fitText() {
  document.querySelectorAll('.text-layer span').forEach(node => {
    if (!node.offsetWidth) return;
    const target = node.parentElement.clientWidth * Number(node.dataset.width) / 100;
    if (target > 0) node.style.transform = 'scaleX(' + target / node.offsetWidth + ')';
  });
}
buttons.forEach(node => node.addEventListener('click', () => setMode(node.dataset.mode)));
window.addEventListener('resize', fitText);
if (document.fonts) document.fonts.ready.then(fitText);
requestAnimationFrame(fitText);
"""


def chapter_plan(toc, count):
    """Classify Hyperref named destinations, not hierarchy depth (appendices vary)."""
    sections = []
    for level, title, start, dest in toc:
        name = dest.get("nameddest", "")
        if not TOP.match(name):
            continue
        if not 1 <= start <= count:
            raise ValueError(f"Invalid destination {name}: {start}")
        match = NUMBERED.fullmatch(name)
        if match:
            kind, number = match.groups()
            slug = f"{kind}-{number.lower()}"
            label = f"{kind.title()} {number}: {title}" if kind != "part" else title
        else:
            kind = "front" if name.startswith("chapter*") else "appendix"
            slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
            label = title
        sections.append(dict(title=label, kind=kind, start=start, slug=slug, destination=name))
    if not any(s["kind"] == "chapter" for s in sections):
        raise ValueError("No chapter destinations found in the compiled PDF")
    if not any(s["kind"] == "appendix" for s in sections):
        raise ValueError("No appendix destinations found")
    if not any(s["title"] == "Subject and API index" for s in sections):
        raise ValueError("Missing subject/API index")
    if sections[0]["start"] > 1:
        sections.insert(0, dict(title="Title and publication information", kind="front",
                                start=1, slug="publication-information", destination="Doc-Start"))
    starts = [s["start"] for s in sections]
    if starts != sorted(set(starts)):
        raise ValueError(f"Chapter/part destinations are not strictly increasing: {starts}")
    if len({s["slug"] for s in sections}) != len(sections):
        raise ValueError("Duplicate chapter filenames")
    for i, section in enumerate(sections):
        section["end"] = sections[i+1]["start"] - 1 if i+1 < len(sections) else count
        section["file"] = section["slug"] + ".html"
    coverage = [n for s in sections for n in range(s["start"], s["end"]+1)]
    if coverage != list(range(1, count+1)):
        raise ValueError("HTML chapter plan does not cover the PDF exactly once")
    return sections


def document(title, body, asset, script=False):
    return ('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<meta name="description" content="Modern Perl Concurrency — online handbook">'
            f'<title>{esc(title)} | Modern Perl Concurrency</title>'
            f'<link rel="stylesheet" href="assets/reader-{asset}.css"></head><body>'
            + body + (f'<script src="assets/reader-{asset}.js" defer></script>' if script else "")
            + '</body></html>\n')


def write(path, content):
    path.write_text(content, encoding="utf-8")


def position(rect, page):
    x0, y0, x1, y1 = rect
    x0 -= page.rect.x0
    x1 -= page.rect.x0
    y0 -= page.rect.y0
    y1 -= page.rect.y0
    w, h = page.rect.width, page.rect.height
    return (f"left:{100*x0/w:.5f}%;top:{100*y0/h:.5f}%;"
            f"width:{100*(x1-x0)/w:.5f}%;height:{100*(y1-y0)/h:.5f}%")


def render_page(page, number, out, asset, page_files, names):
    filename = f"page-{number:04d}-{asset}.svg"
    svg = page.get_svg_image(text_as_path=True)
    if "<svg" not in svg or not svg.strip().endswith("</svg>"):
        raise ValueError(f"Invalid SVG on page {number}")
    write(out / "pages" / filename, svg)
    spans = []
    for block in page.get_text("dict", flags=fitz.TEXTFLAGS_TEXT, sort=True)["blocks"]:
        for line in block.get("lines", []):
            for span in line["spans"]:
                text = span["text"]
                if not text.strip():
                    continue
                width = (span["bbox"][2] - span["bbox"][0]) / page.rect.width * 100
                size = span["size"] / page.rect.width * 100
                family = "monospace" if span["flags"] & 8 else "serif"
                style = position(span["bbox"], page).split(";width:")[0]
                spans.append(f'<span data-width="{width:.5f}" style="{style};'
                             f'font-size:{size:.5f}cqw;font-family:{family}">{esc(text)}</span>')
    links = []
    for link in page.get_links():
        kind = link.get("kind")
        dest = link.get("page", -1)
        if kind == fitz.LINK_NAMED and dest < 0:
            dest = names.get(link.get("nameddest", ""), {}).get("page", -1)
        if kind in (fitz.LINK_GOTO, fitz.LINK_NAMED) and dest + 1 in page_files:
            href = f"{page_files[dest+1]}#page-{dest+1}"
            label = f"Go to handbook page {dest+1}"
        elif kind == fitz.LINK_URI and urlsplit(link.get("uri", "")).scheme.lower() in ("https", "http", "mailto"):
            href = link["uri"]
            label = href
        else:
            continue
        links.append(f'<a class="pdf-link" href="{esc(href, quote=True)}" '
                     f'aria-label="{esc(label, quote=True)}" style="{position(link["from"], page)}"></a>')
    transcript = page.get_text("text", sort=True)
    return (f'<section class="reading-page" id="page-{number}" aria-label="PDF page {number}">'
            f'<div class="page-label"><span>PDF page {number}</span>'
            f'<a href="../modern-perl-concurrency.pdf#page={number}">Open in PDF</a></div>'
            f'<div class="sheet"><img src="pages/{filename}" alt="" loading="lazy" '
            f'width="{page.rect.width:.0f}" height="{page.rect.height:.0f}">'
            '<div class="text-layer">' + "\n".join(spans) + '</div>' + "".join(links) + '</div>'
            f'<div class="transcript" hidden><pre>{esc(transcript)}</pre></div></section>')


def navigation(sections, i):
    prev = f'<a rel="prev" href="{sections[i-1]["file"]}">← Previous</a>' if i else ""
    nxt = f'<a rel="next" href="{sections[i+1]["file"]}">Next →</a>' if i+1 < len(sections) else ""
    return f'<nav aria-label="Chapter navigation">{prev}<a href="index.html">All chapters</a>{nxt}<a href="../index.html">Project portal</a></nav>'


def render(pdf, out, commit, tag):
    with fitz.open(pdf) as doc:
        toc = doc.get_toc(simple=False)
        sections = chapter_plan(toc, len(doc))
        page_files = {n: s["file"] for s in sections for n in range(s["start"], s["end"]+1)}
        names = doc.resolve_names()
        digest = hashlib.sha256(pdf.read_bytes()).hexdigest()
        asset = digest[:16]
        if out.exists():
            shutil.rmtree(out)
        (out / "pages").mkdir(parents=True)
        (out / "assets").mkdir()
        write(out / "assets" / f"reader-{asset}.css", CSS)
        write(out / "assets" / f"reader-{asset}.js", JS)
        for i, section in enumerate(sections):
            title = section["title"]
            start, end = section["start"], section["end"]
            subsection_links = []
            for _, heading, page, dest in toc:
                if start <= page <= end and dest.get("nameddest", "").startswith(("section.", "subsection.")):
                    subsection_links.append(f'<li><a href="#page-{page}">{esc(heading)}</a></li>')
            jumps = ('<details class="panel section-nav"><summary>Sections in this chapter</summary><ul>'
                     + "".join(subsection_links) + '</ul></details>') if subsection_links else ""
            nav = navigation(sections, i)
            header = (f'<header><div class="wrap"><div class="eyebrow">Modern Perl Concurrency · Online handbook</div>'
                      f'<h1>{esc(title)}</h1><small>PDF pages {start}–{end} · {esc(tag)} · {esc(commit[:12])}</small>{nav}</div></header>')
            controls = ('<div class="panel controls"><nav aria-label="Reading mode">'
                        '<button type="button" data-mode="layout" aria-pressed="true">Illustrated layout</button>'
                        '<button type="button" data-mode="text" aria-pressed="false">Reflowable text</button>'
                        '</nav><small>Layout preserves every illustration and listing; text mode is a PDF-derived '
                        'transcript, not a semantic or code-source conversion. Copy runnable code from the '
                        '<a href="../index.html">canonical examples</a>.</small></div>')
            pages = "".join(render_page(doc[n-1], n, out, asset, page_files, names)
                            for n in range(start, end+1))
            body = header + '<main class="wrap">' + controls + jumps + pages + nav + '</main>'
            body += '<footer class="wrap"><a href="../index.html">Modern Perl Concurrency</a> · CC BY 4.0</footer>'
            write(out / section["file"], document(title, body, asset, True))

        contents = "".join(f'<li><a href="{s["file"]}">{esc(s["title"])}</a> '
                           f'<small>pages {s["start"]}–{s["end"]}</small></li>' for s in sections)
        body = ('<header><div class="wrap"><div class="eyebrow">Modern Perl Concurrency</div>'
                '<h1>Read the handbook online</h1><nav><a href="../index.html">Project portal</a>'
                '<a href="../modern-perl-concurrency.pdf">Complete PDF</a></nav>'
                f'<small>{esc(tag)} · {esc(commit[:12])}</small></div></header>'
                '<main class="wrap"><section class="panel"><h2>Full contents</h2>'
                '<p>Every page of the verified handbook, including diagrams, code, appendices and index. '
                'Choose a chapter to read in your browser.</p><ol>' + contents + '</ol></section></main>')
        write(out / "index.html", document("Full contents", body, asset))
        manifest = dict(commit=commit, tag=tag, pdf_sha256=digest, page_count=len(doc), chapters=sections)
        write(out / "manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        if len(list((out / "pages").glob("*.svg"))) != len(doc):
            raise ValueError("Missing or duplicate rendered pages")
        for section in sections:
            path = out / section["file"]
            if not path.is_file() or path.stat().st_size == 0:
                raise ValueError(f"Missing HTML chapter {path}")
        print(f"HTML reader: {len(sections)} sections, {len(doc)} PDF pages, SHA-256 {digest}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pdf", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    render(args.pdf, args.output, args.commit, args.tag)
