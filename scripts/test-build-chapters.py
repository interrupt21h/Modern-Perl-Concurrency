#!/usr/bin/env python3
"""Regression test for the handbook's Hyperref destination conventions."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

import fitz

spec = importlib.util.spec_from_file_location("reader", Path(__file__).with_name("build-chapters.py"))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class ReaderTests(unittest.TestCase):
    def fixture(self):
        toc = [[1, "Reading this handbook", 3, {"nameddest": "chapter*.1"}]]
        for n, roman in enumerate(("I", "II", "III", "IV", "V", "VI"), 1):
            toc.extend([
                [1, f"{roman} Part title {n}", 2*n+3, {"nameddest": f"section*.{n+2}"}],
                [2, f"Chapter title {n}", 2*n+4, {"nameddest": f"chapter.{n}"}],
                [3, "Subsection", 2*n+4, {"nameddest": f"section.{n}.1"}],
            ])
        toc.extend([
            [2, "Laboratory", 17, {"nameddest": "appendix.A"}],
            [2, "Subject and API index", 19, {"nameddest": "section*.9"}],
        ])
        return toc

    def test_complete_coverage(self):
        plan = reader.chapter_plan(self.fixture(), 20)
        self.assertEqual(plan[0]["slug"], "publication-information")
        self.assertEqual(plan[-1]["slug"], "subject-and-api-index")
        self.assertEqual(sum(s["kind"] == "part" for s in plan), 6)
        self.assertEqual([p for s in plan for p in range(s["start"], s["end"]+1)], list(range(1, 21)))
        self.assertEqual(next(s for s in plan if s["slug"] == "chapter-1")["start"], 6)

    def test_missing_index_fails(self):
        with self.assertRaises(ValueError):
            reader.chapter_plan(self.fixture()[:-1], 20)

    def test_page_renderer(self):
        with tempfile.TemporaryDirectory() as tmp, fitz.open() as doc:
            doc.new_page()
            doc.new_page()
            p = doc[0]
            p.insert_text((72, 72), "Perl <code> & diagram")
            p.draw_rect(fitz.Rect(72, 100, 200, 170))
            p.insert_link({"kind": fitz.LINK_GOTO, "from": fitz.Rect(70, 60, 210, 80),
                           "page": 1, "to": fitz.Point(0, 0)})
            with fitz.open("pdf", doc.tobytes()) as reopened:
                out = Path(tmp)
                (out / "pages").mkdir()
                result = reader.render_page(reopened[0], 1, out, "fixture",
                                            {1: "chapter-1.html", 2: "chapter-2.html"}, {})
                self.assertIn("Perl &lt;code&gt; &amp; diagram", result)
                self.assertIn("chapter-2.html?v=fixture#page-2", result)
                self.assertIn('class="transcript" hidden', result)
                self.assertIn("<svg", (out / "pages/page-0001-fixture.svg").read_text())


if __name__ == "__main__":
    unittest.main()
