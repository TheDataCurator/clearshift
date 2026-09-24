#!/usr/bin/env python3
"""Verify the application holds together before deploying or sharing.

Checks the contracts that have actually broken during development, so a future
edit cannot quietly undo them:

  - the rule that hides inactive sections exists
  - nav buttons, sections, routes, page titles and loaders all name the same views
  - every loader referenced is defined, exactly once
  - every sub-tab has a matching pane
  - the markup is balanced, so sections cannot nest inside one another
  - the JavaScript parses

Exits non-zero on any failure. Run from the repository root:

    python3 check.py
"""

from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
FE = ROOT / "app" / "frontend"

failures: list[str] = []
notes: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)


def block(text: str, pattern: str) -> str:
    m = re.search(pattern, text, re.S)
    if not m:
        fail(f"could not find {pattern!r}")
        return ""
    return m.group(1)


def main() -> int:
    html = (FE / "index.html").read_text()
    js = (FE / "app.js").read_text()
    css = (FE / "styles.css").read_text()

    # 1. Inactive sections must actually be hidden. Losing this rule paints every
    #    section at once, which reads as one long page rather than a set of views.
    if not re.search(r"\.view\.hidden[^{]*\{[^}]*display:\s*none", css):
        fail("styles.css: .view.hidden does not set display:none")

    # 2. One vocabulary of view names, used everywhere.
    nav = set(re.findall(r'data-view="(\w+)"', html))
    sections = set(re.findall(r'id="view-(\w+)"', html))
    views = set(re.findall(r"'(\w+)'", block(js, r"const VIEWS = \[(.*?)\];")))
    titles = set(re.findall(r"(\w+):", block(js, r"const PAGE_TITLE = \{(.*?)\n\};")))
    loaders_src = block(js, r"const LOADERS = \{(.*?)\};")
    loaders = set(re.findall(r"(\w+):\s*load\w+", loaders_src))

    for label, other in [
        ("sections", sections),
        ("VIEWS", views),
        ("PAGE_TITLE", titles),
        ("LOADERS", loaders),
    ]:
        diff = nav ^ other
        if diff:
            fail(f"nav buttons and {label} disagree on: {sorted(diff)}")
    notes.append(f"{len(nav)} views, consistent across nav, sections, routes, titles, loaders")

    # 3. Every loader named must exist, and only once. A missing one throws during
    #    initialisation and stops the nav being wired at all.
    named = [fn for _, fn in re.findall(r"(\w+):\s*(\w+)", loaders_src)]
    for fn in named:
        if f"function {fn}" not in js:
            fail(f"LOADERS references {fn}, which is not defined")

    defined = re.findall(r"(?:async )?function (\w+)\(", js)
    dupes = sorted({f for f in defined if defined.count(f) > 1})
    if dupes:
        fail(f"functions defined more than once: {dupes}")

    # 4. Sub-tabs and their panes must correspond, or a tab shows nothing.
    for nav_id, prefix in [("osha-mode", "osha-pane"),
                           ("lrn-mode", "lrn-pane"),
                           ("ov-mode", "ov-pane")]:
        m = re.search(rf'id="{nav_id}".*?</nav>', html, re.S)
        modes = set(re.findall(r'data-mode="(\w+)"', m.group(0))) if m else set()
        panes = set(re.findall(rf'id="{prefix}-(\w+)"', html))
        if not modes:
            fail(f"{nav_id}: no sub-tabs found")
        diff = modes ^ panes
        if diff:
            fail(f"{nav_id}: sub-tabs and panes disagree on: {sorted(diff)}")
    notes.append("sub-tabs match their panes in all three grouped sections")

    # 5. Balanced markup. An unclosed div swallows the sections after it, so
    #    hiding the outer section cannot hide what is nested inside.
    for m in re.finditer(r'<section id="view-(\w+)"(.*?)</section>', html, re.S):
        name, body = m.group(1), m.group(2)
        if len(re.findall(r"<div\b", body)) != body.count("</div>"):
            fail(f"section {name}: unbalanced div tags")
    opened, closed = len(re.findall(r"<div\b", html)), html.count("</div>")
    if opened != closed:
        fail(f"index.html: {opened} <div> against {closed} </div>")
    if html.count("<section") != html.count("</section>"):
        fail("index.html: unbalanced section tags")
    notes.append("markup balanced")

    # 6. Nav label and page heading must read the same, so a viewer knows where
    #    they landed.
    for m in re.finditer(r'data-view="(\w+)"[^>]*>\s*<span[^>]*>[^<]*</span>([^<]+)</button>', html):
        view, label = m.group(1), m.group(2).strip()
        sec = re.search(rf'id="view-{view}"(.*?)</section>', html, re.S)
        if not sec:
            continue
        h2 = re.search(r"<h2>(.*?)</h2>", sec.group(1), re.S)
        if view == "home" or not h2:
            continue
        heading = re.sub(r"\s+", " ", h2.group(1)).strip()
        if label.lower() != heading.lower():
            fail(f"view {view}: nav says {label!r}, heading says {heading!r}")


    # 8. Every documentation tab must resolve to content: either a DOCS entry or
    #    the one tab that is fetched.
    doc_tabs = re.findall(r'data-doc="(\w+)"', html)
    docs_keys = set(re.findall(r"^  (\w+): `", js, re.M))
    for t in doc_tabs:
        if t not in docs_keys and f"'{t}'" not in js:
            fail(f"documentation tab {t!r} has no content")
    notes.append(f"{len(doc_tabs)} documentation tabs resolve to content")

    # 7. The JavaScript must parse.
    if shutil.which("node"):
        r = subprocess.run(["node", "--check", str(FE / "app.js")],
                           capture_output=True, text=True)
        if r.returncode != 0:
            fail("app.js does not parse:\n" + r.stderr.strip())
        else:
            notes.append("app.js parses")
    else:
        notes.append("node not available; skipped the parse check")

    for n in notes:
        print(f"  ok   {n}")
    for f in failures:
        print(f"  FAIL {f}")
    print()
    print("PASS" if not failures else f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
