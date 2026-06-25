#!/usr/bin/env python3
"""Generate the Examples index pages for the MkDocs site.

Walks docs/examples/<tier>/<name>/index.md and writes signpost landing pages
(Material "grid cards"): one central docs/examples/index.md grouped by tier, and
one docs/examples/<tier>/index.md per tier (so each nav group has its own landing
instead of borrowing the first example's page). Card title + blurb are pulled
from each example's `# H1` and its `!!! abstract "What"` admonition.

Pure signpost generator — it never touches the example pages themselves. Re-run
after adding, renaming, or re-describing an example:

    python3 scripts/gen-examples-index.py
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, "docs", "examples")
TIERS = [
    ("real-world", "Real-world use cases",
     "Real public datasets — each page cites its source and the documented "
     "problem it solves."),
    ("basic", "Teaching — basic",
     "Synthetic, minimal inputs that isolate one engine feature at a time."),
    ("intermediate", "Teaching — intermediate",
     "Synthetic examples combining a few features."),
    ("advanced", "Teaching — advanced",
     "Synthetic multi-pass pipelines, joins, and capstones."),
]


def title_and_blurb(index_md):
    text = open(index_md, encoding="utf-8").read()
    tm = re.search(r"^# (.+)", text, re.M)
    title = tm.group(1).strip() if tm else os.path.basename(os.path.dirname(index_md))
    # Body of the `!!! abstract "What"` admonition: the 4-space-indented lines
    # immediately after the marker, up to the first blank/unindented line.
    blurb = ""
    am = re.search(r'^!!! abstract "What"\n((?:    .*\n?)+)', text, re.M)
    if am:
        body = " ".join(l.strip() for l in am.group(1).splitlines())
        body = re.sub(r"\s+", " ", body).strip()
        sm = re.match(r"(.+?[.!?])(\s|$)", body)
        blurb = sm.group(1) if sm else body
    return title, blurb


def examples_in(tier):
    base = os.path.join(BASE, tier)
    out = []
    for name in sorted(os.listdir(base)):
        idx = os.path.join(base, name, "index.md")
        if os.path.isfile(idx):
            out.append((name, *title_and_blurb(idx)))
    return out


def grid(items, link_prefix):
    lines = ['<div class="grid cards" markdown>', ""]
    for name, title, blurb in items:
        lines.append(f"-   **[{title}]({link_prefix}{name}/index.md)**")
        lines.append("")
        if blurb:
            lines.append(f"    {blurb}")
            lines.append("")
    lines += ["</div>", ""]
    return "\n".join(lines)


def write_central():
    out = [
        "# Examples", "",
        "Runnable demonstrations of one data problem each — config, input, and the",
        "exact transformation. Open any card for the full story; the **View on",
        "GitHub** button on each page links the complete files to run it yourself.",
        "",
    ]
    for slug, heading, intro in TIERS:
        items = examples_in(slug)
        if not items:
            continue
        out += [f"## {heading}", "", intro, "", grid(items, f"{slug}/")]
    path = os.path.join(BASE, "index.md")
    open(path, "w", encoding="utf-8").write("\n".join(out).rstrip() + "\n")
    return path


def write_tier(slug, heading, intro):
    items = examples_in(slug)
    if not items:
        return None
    out = [f"# {heading}", "", intro, "", grid(items, "")]
    path = os.path.join(BASE, slug, "index.md")
    open(path, "w", encoding="utf-8").write("\n".join(out).rstrip() + "\n")
    return path


def main():
    written = [write_central()]
    for slug, heading, intro in TIERS:
        p = write_tier(slug, heading, intro)
        if p:
            written.append(p)
    for p in written:
        print("wrote", os.path.relpath(p, ROOT))


if __name__ == "__main__":
    main()
