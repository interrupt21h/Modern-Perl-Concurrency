# Publication layout contract

This is the stable design guidance for **Modern Perl Concurrency**. Treat these as constraints when editing the handbook, quick reference, or CI. The source baseline is the 288-page publication from run 45641996246 (before the extra floating quick-reference illustrations), not an instruction to revert later content or tests.

## Handbook

- Preserve the plain typographic cover, six part dividers, running headers, numbered chapters and hierarchy. US Letter, 11 pt body, 1.05-inch margins, 1.12 line stretch and 8 pt paragraph spacing. Sections have 19 pt above and 8 pt below; tables use 1.20 row spacing unless locally tuned.
- Retain the navy/teal palette and differentiated semantic callouts: engineering note teal (#006F73), correctness warning rust (#943E29), version note ochre (#76560D), historical evidence navy (#16324A), practical tip green (#386329). Use dark title bands with white text, subtle 5% body tint and explicit titles so color is never the only cue. Preserve strategy-card titles and body padding (11 pt horizontal, 9–10 pt vertical), chapter reading-objective panels, and teal section numerals. Keep numbered syntax-highlighted, page-breakable code listings with 13 pt separation and continuation headings; use blue-gray headers for ordinary code and warm headers for Redis server scripts, including embedded scripts. Do not reduce type or leading globally to save pages.
- Establish the idea in prose or the plain-language analogy before technical diagrams. Compact shared visual models live inside the relevant strategy card, adjacent to its analogy, or in a compact non-floating inline panel after introductory prose. Keep every detailed original figure and its label. Do not insert independent large quick-reference floats before headings or at the start of a section.
- Diagrams use one canonical vector source, sans-serif labels, bounded enlargement in strategy cards (47% of card width and 58 pt total height), maximum dimensions elsewhere, and arrows that do not cross labels or unrelated lines. Reserve full-width layouts for complex architecture or sequence diagrams.
- Do not split an illustration from its explanation. Place the execution-model overview in its discussion rather than on a detached float page. Avoid unnecessary forced page breaks before ownership/scope and mechanism-selection sections. Use APPENDIX, not CHAPTER, for appendix openers. Avoid headings at page bottoms, stranded callout titles, unnecessary blank space, dense unbroken text and oversized repeated diagrams. Inspect full pages, not only word bounds. Appendix, part and copyright pages have intentional whitespace.

## Illustrated quick reference

- Exactly two landscape US Letter pages, fixed four-column × three-row grid, 24 numbered cards. Keep dimensions, margins, color, font hierarchy and content readable at 100% print scale.
- Typeset diagram boxes independently of the page overlay; center and fit within 158 × 46 PDF points without cropping or non-uniform scaling. Keep all diagram labels, arrows and outlines inside the card. No ink in card gutters. Titles, prose and API lines must not overlap.
- Keep source and standalone release export equivalent. Do not change the shared artwork solely to fix a consumer's placement.

## Verification and review

- CI checks source layout invariants, exact artwork coverage, PDF preflight and all 24 card regions. Render every handbook page and both cheat-sheet pages; generate a page-level layout review report with sparse-page candidates. A successful CI build is not a claim of manual visual approval.
- When a layout change is made, compare contact sheets and affected pages to the previous approved PDF. Review both PDF and the chapter HTML derived from it. Use full-size page inspection for diagrams and code listings; report any unverified visual review explicitly.
- Prefer localized adjustments, preserve technical corrections, and make design changes in shared styles rather than silently changing the typography or removing content.
