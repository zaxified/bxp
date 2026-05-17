#!/usr/bin/env python3
"""Generate synthetic input.in.csv + bxp-cli.json for a single bench run.

Layout of generated CSV:
  fixed cols:    id, name, date, amount
  extra cols:    col4, col5, ... colC-1  (filled with cell_width-byte ASCII)

Default config has three expressions exercising distinct runtime profiles:
  $date_iso   = DATE_CONVERT([date], 'DD.MM.YYYY', 'YYYY-MM-DD')   parser-heavy
  $category   = IF([amount] > 100, 'high', 'low')                   branch + numeric
  $full_label = [id] & '-' & [name] & '-' & [date]                  string alloc (& op)

With --passthrough-only, the config is reduced to plain column passthrough
(no expressions) — used to isolate expr overhead.
"""
import argparse
import json
import os
import random
import string


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, required=True)
    ap.add_argument("--cols", type=int, required=True)
    ap.add_argument("--cell-width", type=int, default=20)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--passthrough-only", action="store_true")
    args = ap.parse_args()

    fixed = ["id", "name", "date", "amount"]
    if args.cols < len(fixed):
        raise SystemExit(f"--cols must be >= {len(fixed)}")
    extra = [f"col{i}" for i in range(len(fixed), args.cols)]
    all_cols = fixed + extra

    os.makedirs(args.out_dir, exist_ok=True)
    random.seed(42)

    csv_path = os.path.join(args.out_dir, "input.in.csv")
    with open(csv_path, "w") as f:
        f.write(",".join(all_cols) + "\n")
        alphabet = string.ascii_letters + string.digits
        for i in range(args.rows):
            row = [
                str(i),
                f"name{i}",
                f"{(i % 28) + 1:02d}.{(i % 12) + 1:02d}.2024",
                f"{random.uniform(10, 1000):.2f}",
            ]
            for _ in extra:
                row.append("".join(random.choices(alphabet, k=args.cell_width)))
            f.write(",".join(row) + "\n")

    # output_schema may only reference $vars, so every passthrough column
    # gets a trivial $col_<name> input_schema entry routing the raw column.
    passthrough_in = {f"$col_{c}": f"[{c}]" for c in all_cols}
    passthrough_out = {c: f"$col_{c}" for c in all_cols}

    if args.passthrough_only:
        input_schema: dict[str, str] = dict(passthrough_in)
        output_schema = dict(passthrough_out)
    else:
        input_schema = {
            "$date_iso":   "DATE_CONVERT([date], 'DD.MM.YYYY', 'YYYY-MM-DD')",
            "$category":   "IF([amount] > 100, 'high', 'low')",
            "$full_label": "[id] & '-' & [name] & '-' & [date]",
        }
        input_schema.update(passthrough_in)
        output_schema = {
            "date_iso":   "$date_iso",
            "category":   "$category",
            "full_label": "$full_label",
        }
        output_schema.update(passthrough_out)

    config = {
        "conversion_templates": {
            "bench": {
                "data_dir": ".",
                "file_pattern_in": ".in.csv",
                "file_pattern_out": ".out.csv",
                "input_schema": input_schema,
                "row_rules": [{"when": "1 = 1", "rows": [{}]}],
                "output_schema": output_schema,
            }
        }
    }
    with open(os.path.join(args.out_dir, "bxp-cli.json"), "w") as f:
        json.dump(config, f, indent=2)


if __name__ == "__main__":
    main()
