#!/usr/bin/env bash
# Generator for examples/README.md — walks examples/*/*/sample.json and writes a central index
set -euo pipefail
cd "$(dirname "$0")"

README="README.md"
cat > "$README" <<'EOF'
# BXP Examples

Each section is a self-contained example. Open the per-example readme for
the full story, or copy the command into your shell to re-run it from the CLI.

---

EOF

while IFS= read -r -d '' cfg; do
  rel="$(dirname "${cfg#./}")"
  readme="$rel/00-readme.md"
  [[ -f "$readme" ]] || continue
  tpl="$(perl -0777 -ne 'print $1 if /conversion_templates\s*:\s*\{\s*([A-Za-z_]\w*)/' "$cfg")"
  # Demote the per-example h1 to h2 so the central README stays single-h1.
  title=$(grep -m1 '^# '                        "$readme" | sed 's/^# /## /' || true)
  what=$( grep -m1 '^\*\*What\.\*\*'            "$readme" || true)
  why=$(  grep -m1 '^\*\*Why interesting\.\*\*' "$readme" || true)
  {
    echo "$title"
    echo
    echo "$what"
    echo
    echo "$why"
    echo
    echo "📄 [$readme]($readme)"
    echo
    echo '```bash'
    echo "bxp-cli --config ./$rel/sample.json${tpl:+ --template $tpl}"
    echo '```'
    echo
    echo "---"
    echo
  } >> "$README"
done < <(find . -name sample.json -print0 | sort -z)

# Trim trailing separator and collapse any tail of blank lines to exactly one EOL.
perl -i -0777 -pe 's/\n---\n+\z/\n/; s/\n+\z/\n/' "$README"
echo "wrote $README"
