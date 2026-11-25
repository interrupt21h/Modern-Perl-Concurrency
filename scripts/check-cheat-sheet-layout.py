#!/usr/bin/env python3
"""Verify every rendered quick-reference card, not merely the page boundary."""
import sys
from pathlib import Path

import fitz

# PDF coordinates in big points, matching the source's card grid.
COLS = (28, 214, 400, 586)
ROWS = (114, 261, 408)
LABELS = (
    ("execution order", "tasks yield and resume"),
    ("T1", "T3", "shared state"),
    ("parent", "child A", "child B"),
    ("holds lock", "wait"),
    ("3 permits held", "4th task", "wait"),
    ("predicate + same mutex", "recheck", "if still false"),
    ("producer", "consumer"),
    ("all arrive",),
    ("R1", "R2", "exclusive"),
    ("proc A", "proc B", "lock file"),
    ("proc A", "proc B", "kernel permits"),
    ("atomic word", "kernel wait"),
    ("row: 5", "row: 4", "affected rows"),
    ("txn A", "txn B", "row lock"),
    ("v=7", "v=8", "0 rows"),
    ("conn A", "conn B", "named lock"),
    ("job 1", "job 2", "job 3"),
    ("SET NX PX", "token + TTL"),
    ("WATCH", "MULTI", "EXEC"),
    ("Redis: compare", "then modify"),
    ("41 stale", "42 new", "destination"),
    ("atomic permit set + expiry", "wait"),
    ("add", "owned", "gone"),
    ("req A", "retry", "saved result"),
)


def ink_in(page, rect):
    # Render guard strips, catching arrows and shapes as well as text.
    pix = page.get_pixmap(matrix=fitz.Matrix(3, 3), clip=fitz.Rect(rect),
                          colorspace=fitz.csRGB, alpha=False)
    return any(v < 235 for v in pix.samples)


def main():
    errors = []
    with fitz.open(Path(sys.argv[1])) as doc:
        if len(doc) != 2:
            raise SystemExit("Expected exactly two cheat-sheet pages")
        for p, page in enumerate(doc):
            if abs(page.rect.width - 792) > 1 or abs(page.rect.height - 612) > 1:
                raise SystemExit("Expected US letter landscape")
            for i, y in enumerate(ROWS):
                for j, x in enumerate(COLS):
                    n = p * 12 + i * 4 + j
                    area = fitz.Rect(x + 8, y + 27, x + 170, y + 78)
                    words = " ".join(page.get_text("text", clip=area).split())
                    missing = [label for label in LABELS[n] if label not in words]
                    if missing:
                        errors.append(f"Card {n + 1:02}: missing diagram text {missing}")
                    for side, rect in (
                        ("left", (x + 3, y + 28, x + 8, y + 77)),
                        ("right", (x + 170, y + 28, x + 175, y + 77)),
                        ("bottom", (x + 8, y + 77, x + 170, y + 79)),
                    ):
                        if ink_in(page, rect):
                            errors.append(f"Card {n + 1:02}: diagram crosses {side} guard")
                    # The next card cannot conceal overflow through the gutter.
                    if j < len(COLS) - 1 and ink_in(
                        page, (x + 180, y + 28, x + 184, y + 77)
                    ):
                        errors.append(f"Card {n + 1:02}: ink in inter-card gutter")
    if errors:
        raise SystemExit("\n".join(errors))
    print("Cheat-sheet layout: all 24 cards have expected labels and clear guard strips")


if __name__ == "__main__":
    main()
