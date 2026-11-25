#!/usr/bin/env python3
"""Build a static handbook portal and full chapter reader from validated CI outputs."""
import hashlib
import json
import html
import os
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "site-dist"
DIST = ROOT / "dist"
REPO = "https://github.com/" + os.environ["GITHUB_REPOSITORY"]
TAG = os.environ["RELEASE_TAG"]
SHA = os.environ["PUBLISHED_SHA"]
RUN = os.environ["GITHUB_RUN_ID"]
PDF = "modern-perl-concurrency.pdf"
SOURCE = "formatted-source.tar.gz"
esc = html.escape

OUT.mkdir(exist_ok=True)
assets = {}
for name in (PDF, SOURCE, "SHA256SUMS", "tidy-build.txt", "perl-concurrency-cheat-sheet.pdf", "cheat-sheet.tex", "verification.json", "benchmark-results.txt"):
    shutil.copy2(DIST / name, OUT / name)
    digest = hashlib.sha256((DIST / name).read_bytes()).hexdigest()
    assets[name] = f"{REPO}/releases/download/{quote(TAG, safe='')}/{quote(name)}?sha256={digest}"
(OUT / "latest.json").write_text(json.dumps({"tag": TAG, "commit": SHA, "run": RUN, "assets": assets}, indent=2) + "\n", encoding="utf-8")
(OUT / ".nojekyll").touch()

subprocess.run([sys.executable, str(ROOT / "scripts/build-chapters.py"), str(DIST / PDF),
                str(OUT / "book"), "--commit", SHA, "--tag", TAG], check=True)
book = json.loads((OUT / "book/manifest.json").read_text(encoding="utf-8"))
if book["pdf_sha256"] != hashlib.sha256((DIST / PDF).read_bytes()).hexdigest():
    raise SystemExit("HTML and PDF publication inputs differ")
chapter_html = "".join(
    f'<li><a href="book/{esc(chapter["file"], quote=True)}?v={quote(TAG)}">{esc(chapter["title"])}</a>'
    f' <small>pages {chapter["start"]}–{chapter["end"]}</small></li>'
    for chapter in book["chapters"]
)
latest = json.loads((OUT / "latest.json").read_text(encoding="utf-8"))
latest["html"] = {"contents": "book/index.html", "manifest": "book/manifest.json",
                  "page_count": book["page_count"], "pdf_sha256": book["pdf_sha256"]}
(OUT / "latest.json").write_text(json.dumps(latest, indent=2) + "\n", encoding="utf-8")
examples = sorted(p for p in (ROOT / "examples").iterdir() if p.is_file() and p.suffix in {".pl", ".c", ".sql", ".txt"})
example_html = "".join(
    f'<li><a href="{REPO}/blob/{SHA}/{quote(p.relative_to(ROOT).as_posix())}">{esc(p.name)}</a></li>'
    for p in examples
)
release = f"{REPO}/releases/tag/{quote(TAG)}"
run = f"{REPO}/actions/runs/{RUN}"
page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="0">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="Modern Perl Concurrency: Synchronization, Distributed Coordination and Application Architecture. Engineering handbook and executable laboratory.">
<title>Modern Perl Concurrency</title>
<style>
:root {{color-scheme:light dark;--bg:#f5f7fa;--paper:#fff;--ink:#182839;--muted:#516579;--line:#dbe3e9;--accent:#08665f;--hero:#142c40}}
*{{box-sizing:border-box}} body{{margin:0;background:var(--bg);color:var(--ink);font:16px/1.65 system-ui,sans-serif}}
a{{color:var(--accent);text-underline-offset:3px}} a:focus-visible{{outline:3px solid #d69f45;outline-offset:4px}}
header{{background:var(--hero);color:#fff;padding:clamp(2rem,7vw,5rem) 1.25rem}}
header a{{color:#a9e4d9}} .wrap{{max-width:1050px;margin:auto}} .eyebrow{{font-size:.8rem;letter-spacing:.14em;text-transform:uppercase;font-weight:700}}
h1{{font-size:clamp(2.2rem,5vw,3.8rem);line-height:1.08;max-width:850px;margin:.6rem 0 1rem}}
header p{{max-width:720px;color:#d9e6ee}} main{{padding:2rem 1.25rem}} h2{{font-size:1.4rem;margin-top:0}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,280px),1fr));gap:1rem}}
.panel{{background:var(--paper);border:1px solid var(--line);border-radius:12px;padding:1.5rem;margin-bottom:1rem}}
.actions{{display:flex;flex-wrap:wrap;gap:.8rem;margin-top:1.5rem}}
.button{{display:inline-block;background:#b3ece1;color:#123830;padding:.65rem 1rem;border-radius:6px;text-decoration:none;font-weight:700}}
.secondary{{background:transparent;color:#e8f6f5;border:1px solid #8db7bb}}
small,.muted{{color:var(--muted)}} code{{font-size:.9em;overflow-wrap:anywhere}} li{{margin:.35rem 0}} .examples{{columns:2 260px;column-gap:2rem;padding-left:1.25rem}}
footer{{border-top:1px solid var(--line);padding:1.5rem 1.25rem;color:var(--muted)}} 
@media(prefers-color-scheme:dark){{:root{{--bg:#111a22;--paper:#192633;--ink:#e7eef5;--muted:#aebfcc;--line:#344653;--accent:#9be1d4;--hero:#142c40}}}}
</style>
</head>
<body>
<header><div class="wrap">
<div class="eyebrow">Engineering handbook / Edition 2.1.1</div>
<h1>Modern Perl Concurrency</h1>
<p><strong>Synchronization, Distributed Coordination and Application Architecture</strong></p>
<p><a href="{REPO}/releases/tag/v2.1.1">Stable edition</a> · <a href="{esc(assets['verification.json'], quote=True)}">Current verification manifest</a> · <a href="{esc(assets['benchmark-results.txt'], quote=True)}">Measured benchmark trials</a></p>
<p>A six-part engineering reference for local synchronization, persistent state, distributed coordination and production application architecture. Includes a recoverable processing capstone and complete laboratory appendices.</p>
<p><strong>Scott Muller</strong> · <a href="mailto:scott@21h.io">scott@21h.io</a><br>Software Engineer, Matsch Systems<br>Owner &amp; Independent Consultant, 21h Systems</p>
<p><em>This work is an independent technical publication. The views and recommendations expressed herein are solely those of the author and do not necessarily reflect those of his employer or affiliated organizations. Professional affiliations do not imply institutional endorsement.</em></p>
<div class="actions"><a class="button" href="book/index.html?v={quote(TAG)}">Read online</a><a class="button secondary" href="{esc(assets[PDF], quote=True)}">Read the PDF</a><a class="button secondary" href="{esc(assets['perl-concurrency-cheat-sheet.pdf'], quote=True)}">Two-page cheat sheet</a><a class="button secondary" href="{esc(assets[SOURCE], quote=True)}" download>Download source</a><a class="button secondary" href="{esc(release)}">GitHub release</a></div>
</div></header>
<main class="wrap">
<div class="grid"><section class="panel"><h2>Handbook</h2><p>Read the complete, illustrated technical reference with syntax-highlighted code and runnable examples.</p><a href="book/index.html?v={quote(TAG)}">Read all chapters online</a> · <a href="{esc(assets[PDF], quote=True)}" download>Download PDF</a></section>
<section class="panel"><h2>Executable laboratory</h2><p>Explore the formatted sources, build scripts and tests.</p><a href="{esc(REPO)}/tree/{SHA}/examples">Browse all examples on GitHub</a></section>
<section class="panel"><h2>Build provenance</h2><p><a href="?refresh={esc(RUN)}" id="refresh-page">Refresh publication</a> · <a href="{REPO}/releases/latest">Latest release on GitHub</a></p><p>Build <code>{esc(TAG)}</code> · published from commit <code>{SHA[:12]}</code> after formatting checks, available regression tests and PDF compilation. See logs for skipped tests.</p><a href="{esc(assets['tidy-build.txt'], quote=True)}">Verification log</a> · <a href="{esc(assets['SHA256SUMS'], quote=True)}">Checksums</a> · <a href="{esc(run)}">CI run</a></section></div>
<section class="panel"><h2>Printable cheat sheet</h2><p>Two illustrated pages for quick reference: local Perl synchronization and database/distributed coordination. Print double-sided on US Letter.</p><a href="{esc(assets['perl-concurrency-cheat-sheet.pdf'], quote=True)}">Open PDF</a> · <a href="{esc(assets['perl-concurrency-cheat-sheet.pdf'], quote=True)}" download>Download PDF</a> · <a href="{esc(assets['cheat-sheet.tex'], quote=True)}" download>LaTeX source</a></section>
<section class="panel"><h2>Full chapter contents</h2><p>All {book["page_count"]} verified PDF pages, with illustrated HTML layout and a text reading mode. <a href="book/index.html?v={quote(TAG)}">Open the chapter reader</a>.</p><ol>{chapter_html}</ol></section>
<section class="panel"><h2>Source examples</h2><p>Source links point to the exact release commit. Use isolated services for the laboratory.</p><ul class="examples">{example_html}</ul><p><a href="{esc(REPO)}/tree/{SHA}/examples/catalyst-session">Catalyst application source</a></p></section>
</main><footer><div class="wrap">Modern Perl Concurrency · <a href="{esc(REPO)}">Project repository</a> · <a href="{esc(REPO)}/releases">All releases</a></div></footer>
<script>
document.getElementById("refresh-page").addEventListener("click", (event) => {{
  event.preventDefault();
  const url = new URL(location.href);
  url.searchParams.set("refresh", Date.now().toString());
  location.assign(url.href);
}});
</script>
</body></html>"""
(OUT / "index.html").write_text(page, encoding="utf-8")
print(f"Created portal with {len(examples)} source links: {OUT}")
