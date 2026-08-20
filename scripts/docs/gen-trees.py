#!/usr/bin/env python3
"""Generate the repository-layout tree and the test-phase list for the docs.

Both used to be hand-kept, and both had rotted the same way — by omission
rather than by contradiction. The layout tree in `docs/dev/build.md` was
missing `tools/` (the entire docs-generation toolchain), `bxp-core/src/wasm.zig`,
nine files under `scripts/`, and the whole user-facing half of `docs/`. The test
phases were written out five times across the repo.

Nothing here invents a description. Each entry's blurb is read from the file's
own header, using the convention that file type already follows:

    *.zig   the first `//!` module doc-comment block
    *.sh    the comment block under the shebang
    *.py    the module docstring (or that same comment block)
    *.md    the `description:` key of the YAML front matter

Directories have no header to read, so their blurbs are the one catalog in this
file — `DIRS` below. Adding a directory without describing it is an error, not a
blank cell.

Usage (from any directory):
  python3 scripts/docs/gen-trees.py           — write the fragments
  python3 scripts/docs/gen-trees.py --check   — verify committed fragments match
                                                a fresh generation; exit 1 + diff
"""
import difflib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "docs", "includes")

# ── what the tree shows ──────────────────────────────────────────────────────
#
# Explicit rather than "walk everything": a repository tree is a reading aid, so
# `bxp-gui/lib/ui/` earns a line while its forty widgets do not. `depth` is how
# many levels below the entry to expand.
LAYOUT = [
    ("bxp-cli", 2),
    ("bxp-core", 2),
    ("bxp-mcp", 2),
    ("bxp-gui", 1),
    ("bxp-gui-bridge", 2),
    ("tools", 1),
    ("datasets", 0),
    ("docs", 1),
    ("resources", 1),
    ("scripts", 2),
    (".github", 1),
]

# Top-level paths deliberately absent from the tree, with the reason. Every
# tracked top-level entry must be either in LAYOUT or here — see `check_coverage`.
# This is the guard that would have caught `tools/` disappearing from the page.
SKIP = {
    ".gitattributes": "git plumbing",
    ".gitignore": "git plumbing",
    ".mcp.json": "editor/agent configuration, not part of the build",
    ".zigversion": "toolchain pin, read by CI",
    "bxp.code-workspace": "VS Code workspace file",
}

# Files worth naming at the top level even though they are not directories.
ROOT_FILES = ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md",
              "CODE_OF_CONDUCT.md", "LICENSE.md", "CLAUDE.md", "mkdocs.yml"]

# Names never shown, at any depth.
HIDE = {"zig-out", ".zig-cache", "__pycache__", "node_modules", ".venv-docs",
        "site", "build", ".dart_tool", "zig-pkg"}

DIRS = {
    "bxp-cli": "user-facing CLI binary — the conversion engine",
    "bxp-cli/src": "arg parsing, config dispatch, the processing pipeline",
    "bxp-core": "internal shared library (no binary of its own)",
    "bxp-core/src": "the domain layer: parsers, evaluator, config, trace, inspect",
    "bxp-mcp": "MCP server (JSON-RPC 2.0 over stdio) for AI agents",
    "bxp-mcp/src": "entry point, tool catalog, bxp_simulate orchestration",
    "bxp-gui": "Flutter desktop app (Linux / macOS / Windows)",
    "bxp-gui/lib": "Dart source: services (FFI + prefs + updater), store, ui",
    "bxp-gui/packages": "path-dep Dart packages — today just json5_ast",
    "bxp-gui/linux": "Linux Flutter shell + CMake hooks",
    "bxp-gui/macos": "macOS Flutter shell",
    "bxp-gui/windows": "Windows Flutter shell",
    "bxp-gui/web": "web Flutter shell (not shipped; keeps `flutter` happy)",
    "bxp-gui/test": "widget + unit tests, incl. the cross-runner expression corpus",
    "bxp-gui/tool": "developer probes, e.g. the Windows bridge stream check",
    "bxp-gui/fonts": "the bundled UI font, embedded rather than fetched at runtime",
    "bxp-gui/installer": "NSIS script for the Windows installer",
    "bxp-gui-bridge": "Zig FFI shared library — the GUI's single backend",
    "bxp-gui-bridge/src": "C-ABI exports and the marshalling around them",
    "bxp-gui-bridge/test": "re-exec helper binary driving the subprocess tests",
    "tools": "build-time documentation generators (never distributed)",
    "tools/zig-doc-gen": "renders every Zig catalog and @typeInfo page into docs/",
    "tools/dart-doc-gen": "renders the Dart GuiToolDoc pages (runs as a flutter test)",
    "datasets": "anonymized sample data + expected output, gated by test-07",
    "docs": "the MkDocs site — this documentation",
    "docs/getting-started": "install, first conversion, the shipped template library",
    "docs/guide": "user guide: templates, expressions, dates, routing, targets",
    "docs/ai": "agent-facing guides: authoring a broker, gui-mcp, handoff",
    "docs/examples": "the runnable example tree plus its Examples section pages",
    "docs/gui": "bxp-gui user guide: features, preferences, updates, troubleshooting",
    "docs/dev": "developer documentation: build, test, debug, architecture, release",
    "docs/reference": "generated reference pages — do not edit by hand",
    "docs/includes": "generated fragments pulled into hand-written pages",
    "docs/assets": "site assets: stylesheets, the playground JS, the wasm engine",
    "resources": "files shipped inside the release archives",
    "resources/console": "the sample config bundled with the console archives",
    "resources/desktop": "the Linux launcher template bundled with the desktop archives",
    "resources/icons": "SVG variants + build-icons.sh, the single source for app icons",
    "scripts": "test, release and documentation tooling",
    "scripts/docs": "documentation support: site generation, wasm playground, checks",
    "scripts/bench": "developer-only benchmark matrix (not part of test.sh)",
    "scripts/bench/results": "recorded benchmark runs — the baseline a regression is measured against",
    "scripts/docs/mermaid-check": "the mermaid-fence parser behind check-formatting.sh",
    ".github": "CI configuration",
    ".github/workflows": "the CI, docs-publish and release pipelines",
    ".github/ISSUE_TEMPLATE": "GitHub issue forms",
}


def tracked_top_level():
    return {t.split("/")[0] for t in _tracked_set()}


def check_coverage():
    """Every tracked top-level path is either shown or explicitly skipped."""
    shown = {name for name, _ in LAYOUT} | set(ROOT_FILES)
    missing = sorted(tracked_top_level() - shown - set(SKIP))
    if missing:
        sys.exit("gen-trees: tracked top-level paths are neither in LAYOUT nor "
                 "in SKIP — the tree would silently omit them: " + ", ".join(missing))


# ── description harvesting ───────────────────────────────────────────────────

SENTENCE_END = re.compile(r"(?<![A-Z])\.(?:\s|$)")


def _first_sentence(block):
    """First sentence of a comment block, without its full stop.

    Headers wrap, so the blurb is assembled from consecutive comment lines and
    only then cut at the first sentence end. Taking line one alone truncates
    mid-clause — that is how `cli_docs.zig` first rendered as "…: the flag
    table". The lookbehind keeps an initialism like `bxp-cli.json` from ending
    the sentence early.
    """
    text = " ".join(" ".join(line.split()) for line in block).strip()
    if not text:
        return ""
    m = SENTENCE_END.search(text)
    if m:
        text = text[: m.start()]
    return text.strip().rstrip(".")


def _comment_block(lines, marker):
    """Consecutive `marker` lines from the start, stopping at the first gap."""
    block = []
    for line in lines:
        if line.startswith(marker):
            body = line[len(marker):].strip()
            if not body:
                if block:
                    break
                continue
            block.append(body)
        elif block:
            break
    return block


def describe_file(path):
    ext = os.path.splitext(path)[1]
    try:
        with open(path, encoding="utf-8") as fh:
            head = [next(fh, "") for _ in range(60)]
    except (OSError, UnicodeDecodeError):
        return ""

    if ext == ".zig":
        return _first_sentence(_comment_block(head, "//!"))

    if ext in (".sh", ".py"):
        # A module docstring if there is one, else the comment block under the
        # shebang — some scripts open theirs with a bare `#` spacer line.
        quote = '"' * 3
        for i, line in enumerate(head):
            stripped = line.lstrip()
            if stripped.startswith(quote):
                block = [stripped[len(quote):]]
                for cont in head[i + 1:]:
                    if quote in cont or not cont.strip():
                        break
                    block.append(cont)
                return _first_sentence(block)
            if not line.startswith("#"):
                break
        return _first_sentence(_comment_block(head[1:], "#"))

    if ext == ".md":
        if head and head[0].strip() == "---":
            for line in head[1:]:
                if line.strip() == "---":
                    break
                m = re.match(r"description:\s*(.+)", line)
                if m:
                    return _first_sentence([m.group(1).strip("\"'")])
        return ""
    return ""


def describe(rel):
    if rel in DIRS:
        return DIRS[rel]
    full = os.path.join(ROOT, rel)
    if os.path.isdir(full):
        sys.exit(f"gen-trees: directory {rel!r} has no DIRS entry")
    return describe_file(full)


def entries(rel):
    """Tracked children of `rel`, directories first, then files, each sorted."""
    full = os.path.join(ROOT, rel) if rel else ROOT
    # Dotfiles below the root are tooling noise in a layout diagram — the ones
    # that matter (`.github/`) are named explicitly in LAYOUT.
    names = [n for n in os.listdir(full) if n not in HIDE and not n.startswith(".")]
    dirs, files = [], []
    for n in sorted(names):
        child = os.path.join(rel, n) if rel else n
        if os.path.isdir(os.path.join(ROOT, child)):
            # A directory holding nothing tracked is a build artifact under a
            # name HIDE happens not to list; it does not belong in a layout.
            if any(t.startswith(child + "/") for t in _tracked_set()):
                dirs.append(n)
        elif tracked(child):
            files.append(n)
    return dirs + files


_TRACKED = None


def _tracked_set():
    global _TRACKED
    if _TRACKED is None:
        out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True,
                             text=True, check=True).stdout
        _TRACKED = set(out.splitlines())
    return _TRACKED


def tracked(rel):
    return rel in _tracked_set()


# ── rendering ────────────────────────────────────────────────────────────────

def render(lines, rel, depth, prefix):
    kids = entries(rel)
    for i, name in enumerate(kids):
        last = i == len(kids) - 1
        child = os.path.join(rel, name)
        is_dir = os.path.isdir(os.path.join(ROOT, child))
        label = name + "/" if is_dir else name
        lines.append((prefix + ("└── " if last else "├── ") + label, describe(child)))
        if is_dir and depth > 0:
            render(lines, child, depth - 1, prefix + ("    " if last else "│   "))


def repo_tree():
    lines = [("bxp/", "monorepo root (git root)")]
    items = LAYOUT + [(f, 0) for f in ROOT_FILES]
    for i, (name, depth) in enumerate(items):
        last = i == len(items) - 1
        is_dir = os.path.isdir(os.path.join(ROOT, name))
        lines.append((("└── " if last else "├── ") + name + ("/" if is_dir else ""),
                      describe(name)))
        if is_dir and depth > 0:
            render(lines, name, depth - 1, "    " if last else "│   ")

    width = max(len(t) for t, _ in lines) + 2
    body = "\n".join(
        (tree.ljust(width) + "# " + desc).rstrip() if desc else tree
        for tree, desc in lines
    )
    return fragment("the repository, walked", "tree",
                    "```diagram\n" + body + "\n```")


def test_phases():
    names = sorted(n for n in os.listdir(os.path.join(ROOT, "scripts"))
                   if re.fullmatch(r"test-\d\d-.*\.sh", n))
    if not names:
        sys.exit("gen-trees: no test-NN-*.sh phases found")
    rows = ["| Phase | What it covers |", "| --- | --- |"]
    for n in names:
        desc = describe_file(os.path.join(ROOT, "scripts", n))
        rows.append(f'| <code class="hl-fn">{n}</code> | {cell(desc)} |')
    return fragment("scripts/test-NN-*.sh headers", "table", "\n".join(rows))


def cell(text):
    """Escape what would break a Markdown table cell.

    `|` ends the cell; `<` is subtler — Markdown passes raw HTML through, so a
    header mentioning `datasets/<template>/` would have `<template>` parsed as
    an unknown element and dropped, truncating the sentence on the page. Mirrors
    `docs.writeEscaped` on the Zig side, minus the code-span handling these
    plain-comment sources never need.
    """
    return text.replace("|", "\\|").replace("<", "&lt;").replace(">", "&gt;")


def fragment(source, section, body):
    return (f"<!-- GENERATED by scripts/docs/gen-trees.py from {source}. "
            f"Do not edit. -->\n\n"
            f"<!-- --8<-- [start:{section}] -->\n\n{body}\n\n"
            f"<!-- --8<-- [end:{section}] -->\n")


FRAGMENTS = {"repo-tree.md": repo_tree, "test-phases.md": test_phases}


def main():
    check = "--check" in sys.argv[1:]
    rc = 0
    for name, build in FRAGMENTS.items():
        fresh = build()
        path = os.path.join(OUT, name)
        if check:
            current = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
            if current != fresh:
                rc = 1
                print(f"DRIFT: docs/includes/{name} is out of sync — run: "
                      f"python3 scripts/docs/gen-trees.py")
                sys.stdout.writelines(difflib.unified_diff(
                    current.splitlines(True), fresh.splitlines(True),
                    "committed", "generated"))
        else:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(fresh)
            print(f"gen-trees: wrote docs/includes/{name}")
    if check and rc == 0:
        print("gen-trees --check: tree + phase fragments in sync")
    sys.exit(rc)


if __name__ == "__main__":
    check_coverage()
    main()
