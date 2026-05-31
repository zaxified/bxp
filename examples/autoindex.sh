#!/usr/bin/env bash
# Generator for examples/README.md — walks the example tree and writes a
# central index grouped by tier: real-world use cases (real public data) first,
# then teaching examples (synthetic, constructed). Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")"

README="README.md"
cat > "$README" <<'EOF'
# BXP Examples

Two kinds of example live here:

- **Real-world use cases** — real, publicly available datasets, each with a
  cited source describing a genuine data problem. The committed `sample.csv` is
  a small real slice; `fetch-full.sh` pulls the complete file for a scale run.
- **Teaching examples** — small, synthetic, constructed inputs that isolate one
  engine feature at a time. The data is fabricated on purpose.

Open a per-example readme for the full story, or copy the command to run it.

EOF

# Emit one example block for the given example directory ($1 = path like
# real-world/imdb-title-basics). Title demoted to h3 under the tier h2.
emit_example() {
  local rel="$1"
  local cfg="$rel/sample.json"
  local readme="$rel/00-readme.md"
  [[ -f "$cfg" && -f "$readme" ]] || return 0
  local tpl title what why
  tpl="$(perl -0777 -ne 'print $1 if /conversion_templates\s*:\s*\{\s*([A-Za-z_]\w*)/' "$cfg")"
  title=$(grep -m1 '^# '                        "$readme" | sed 's/^# /### /' || true)
  what=$( grep -m1 '^\*\*What\.\*\*'            "$readme" || true)
  why=$(  grep -m1 '^\*\*Why interesting\.\*\*' "$readme" || true)
  {
    echo "$title"
    echo
    [[ -n "$what" ]] && { echo "$what"; echo; }
    [[ -n "$why" ]]  && { echo "$why";  echo; }
    echo "📄 [$readme]($readme)"
    echo
    echo '```bash'
    echo "bxp-cli --config ./$rel/sample.json${tpl:+ --template $tpl}"
    echo '```'
    echo
  } >> "$README"
}

# Section helper: heading + intro, then every sample.json under the given dirs.
emit_section() {
  local heading="$1" intro="$2"; shift 2
  local found=()
  local cfg
  while IFS= read -r -d '' cfg; do found+=("$(dirname "${cfg#./}")"); done \
    < <(for base in "$@"; do [[ -d "$base" ]] && find "$base" -name sample.json -print0; done | sort -z)
  [[ ${#found[@]} -eq 0 ]] && return 0
  {
    echo "## $heading"
    echo
    echo "$intro"
    echo
  } >> "$README"
  for rel in "${found[@]}"; do emit_example "$rel"; done
}

emit_section "Real-world use cases" \
  "Real public datasets — each readme cites its source and the documented problem it solves." \
  real-world

emit_section "Teaching examples (synthetic)" \
  "Constructed, minimal inputs that isolate one feature. The data is fabricated, not sourced." \
  basic intermediate advanced

# Collapse any tail of blank lines to exactly one trailing newline.
perl -i -0777 -pe 's/\n+\z/\n/' "$README"
echo "wrote $README"
