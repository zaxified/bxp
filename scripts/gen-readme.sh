#!/usr/bin/env bash
# Generate the two shipped readmes from the single source.
#
#   resources/readme.src.md  ──▶  resources/console/readme.md   (console package)
#                            └─▶  resources/desktop/readme.md   (desktop bundle)
#
# The source tags product-specific lines with HTML-comment block markers that
# survive Markdown rendering even if a generation step is ever skipped:
#
#   <!-- GUI-ONLY:START --> … <!-- GUI-ONLY:END -->   desktop only
#   <!-- CLI-ONLY:START --> … <!-- CLI-ONLY:END -->   console only
#
# Console variant: drop GUI-ONLY blocks, keep CLI-ONLY content (markers stripped).
# Desktop variant: drop CLI-ONLY blocks, keep GUI-ONLY content (markers stripped).
# Everything outside a marked block is shared and appears in both verbatim.
#
# Usage (from any directory):
#   bash scripts/gen-readme.sh            — regenerate both shipped readmes
#   bash scripts/gen-readme.sh --check    — verify the committed readmes match a
#                                           fresh generation; exit 1 + diff on drift
#                                           (wired into scripts/test-01-console.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(dirname "$SCRIPT_DIR")"

CHECK=false
[[ "${1:-}" == "--check" ]] && CHECK=true

CHECK="$CHECK" MONO_ROOT="$MONO_ROOT" python3 - <<'PY'
import os, sys, difflib

mono = os.environ["MONO_ROOT"]
check = os.environ["CHECK"] == "true"

SRC = os.path.join(mono, "resources", "readme.src.md")
OUT = {
    "console": os.path.join(mono, "resources", "console", "readme.md"),
    "desktop": os.path.join(mono, "resources", "desktop", "readme.md"),
}

def generate(variant):
    # console keeps CLI-ONLY + drops GUI-ONLY; desktop is the mirror.
    drop = "GUI-ONLY" if variant == "console" else "CLI-ONLY"
    keep = "CLI-ONLY" if variant == "console" else "GUI-ONLY"
    kept = []
    skipping = False
    with open(SRC) as f:
        for line in f:
            s = line.strip()
            if s == f"<!-- {drop}:START -->":
                skipping = True; continue
            if s == f"<!-- {drop}:END -->":
                skipping = False; continue
            if s in (f"<!-- {keep}:START -->", f"<!-- {keep}:END -->"):
                continue  # strip the marker, keep its content
            if skipping:
                continue
            kept.append(line)

    # Collapse runs of blank lines left by stripped blocks to a single blank —
    # but never inside a fenced code block (blank lines there are content).
    out = []
    in_fence = False
    blank_run = 0
    for line in kept:
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            out.append(line); blank_run = 0; continue
        if not in_fence and line.strip() == "":
            blank_run += 1
            if blank_run > 1:
                continue
        else:
            blank_run = 0
        out.append(line)

    return "".join(out).lstrip("\n").rstrip("\n") + "\n"

rc = 0
for variant, path in OUT.items():
    fresh = generate(variant)
    if check:
        current = open(path).read() if os.path.exists(path) else ""
        if current != fresh:
            rc = 1
            print(f"DRIFT: {os.path.relpath(path, mono)} is out of sync with "
                  f"resources/readme.src.md — run: bash scripts/gen-readme.sh")
            diff = difflib.unified_diff(
                current.splitlines(keepends=True),
                fresh.splitlines(keepends=True),
                fromfile=f"{variant} (committed)", tofile=f"{variant} (generated)")
            sys.stdout.writelines(list(diff)[:40])
    else:
        with open(path, "w") as f:
            f.write(fresh)
        print(f"  wrote {os.path.relpath(path, mono)} ({fresh.count(chr(10))} lines)")

sys.exit(rc)
PY
