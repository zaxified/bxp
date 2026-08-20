---
description: "The binary BXTB frame stream behind --trace: framing, frame types and payload layouts."
---

# BXTB binary trace

Invoked as `bxp-cli --trace [--config ...] [--template ...]`. Writes a binary
**BXTB** frame stream to **stdout**; everything else goes to **stderr**.
`--trace=bin` is an explicit alias; any other `--trace=<x>` argument is a usage
error (there is no NDJSON `--trace=json` path).

The optional `--trace-file <path>` flag mirrors the same byte stream to a file
on disk, so a run can simultaneously drive a downstream consumer on stdout
and persist the stream for offline inspection.

---

## Wire format

The stream begins with a 4-byte little-endian magic `0x42545842` (ASCII
`BXTB`) and is followed by a sequence of frames. There is **no schema-version
field** — bxp-cli and bxp-gui ship together in every release and the magic is
the only handshake.

Each frame has a fixed 7-byte header followed by a type-specific payload:

```text
┌────────────┬────────────┬─────────────────────────────────────────┐
│  byte 0    │  1..2 LE   │  3..6 LE                                │
├────────────┼────────────┼─────────────────────────────────────────┤
│  type:u8   │  chunk:u16 │  pay_len:u32     payload (pay_len B)    │
└────────────┴────────────┴─────────────────────────────────────────┘
```

- `type` — frame kind. Unknown types are silently skipped via `pay_len`
  (forward compat).
- `chunk_id` — reserved for future multicore frame dispatch; producers emit
  `0` today.
- `pay_len` — payload byte count following the header.

Variable-length strings inside payloads are length-prefixed (lp): `u32 len`
little-endian followed by `len` bytes. All multi-byte integers are
little-endian. There are no padding bytes between fields.

Non-frame diagnostics (panics, usage errors, human progress lines) go to
**stderr**. Mixing with stdout is never allowed — `--trace` implies `--quiet`
so summaries never appear on the frame stream.

The authoritative protocol definition lives in
[`bxp-core/src/btrace.zig`](https://github.com/zaxified/bxp/blob/master/bxp-core/src/btrace.zig); this section
documents the same shape for consumers that don't link the Zig writer.

---

## Frame reference

Every frame type the producer can emit, straight from the `FrameType` enum — a
new variant without a description is a compile error in `btrace.zig`, because a
wire-format change nobody wrote down is how a reader ends up skipping frames it
should have handled:

--8<-- "includes/trace-frames.md:table"

Frames carry **metadata only**: per-output-row pointers into the source CSV
(`source_locator` byte offset), error list, pre_pass dump, aggregate stats.
Per-row drill-down (variable values, rule evaluation traces, output cells) is
**not** in the stream — see [Drill-down model](#drill-down-model).

### `0x01 file_start`

```text
input_format:u8       # 0 = csv, 1 = json, 2 = xlsx_intermediate_csv
template:lp_string
path:lp_string
headers_count:u16
headers:lp_string × headers_count
```

The `input_format` enum lets a consumer pick the right re-read strategy for
drill-down: CSV reads via `source_locator` byte offset, JSON re-parses
materialised, xlsx is read as the intermediate CSV exported during processing.

### `0x02 file_end`

```text
source_rows:u64
written_rows:u64
errors:u32           # input_schema expression failures
warnings:u32         # non-fatal per-file issues
```

### `0x03 output_row`

```text
source_locator:u64   # byte offset into the source file for re-read
output_idx:u64       # 1-based output row index within this file
rule_idx:i32         # which row_rules entry produced this output (0-based)
action:lp_string     # $action value, retained for at-a-glance display
```

### `0x04 filtered_row`

```text
source_locator:u64
reason:lp_string     # e.g. "date_filter_from_filename"
```

### `0x05 error_row`

```text
source_locator:u64
var_name:lp_string
error_kind:lp_string
detail:lp_string
origin:lp_string     # "input_schema" | "rule_override" | "pre_pass" | …
```

### `0x06 prepass_entry`

```text
name:lp_string       # pre_pass block name ("_default" for legacy single-block)
key:lp_string
field:lp_string
value:lp_string
```

### `0x07 done`

```text
exit_code:i32
```

| Exit code | Meaning                                                  |
| --------- | -------------------------------------------------------- |
| `0`       | OK.                                                      |
| `1`       | Fatal error (config load, unrecoverable pipeline error). |
| `2`       | Warnings present (e.g. empty input files).               |

---

## Ordering guarantees

For any file, frames appear in this order:

```text
file_start
prepass_entry*                                (may be zero)
( output_row | filtered_row | error_row )*    (one per source row, or many
                                               for 1:N templates that emit
                                               multiple outputs per source row)
file_end
```

`error_row` for a given `source_locator` MAY precede the matching `output_row`
or `filtered_row` — bxp-cli evaluates `input_schema` (which can fail) before
running `row_rules`, so the error frame is emitted as soon as the failure is
known. Consumers should drain pending `error_row`s onto the row when its
output / filtered frame arrives.

Across files, `file_start` / `file_end` pairs are emitted in
`conversion_templates` order; a `file_end` always precedes the next
`file_start`. The stream is closed by exactly one `done` frame. A missing
`done` means the process crashed; consumers should treat stderr as
authoritative in that case.

---

## Drill-down model

The frame stream is deliberately **metadata-only**. Each `output_row` and
`error_row` carries a `source_locator` (byte offset into the source CSV) but
**no** per-row variable bindings, rule evaluation trace, or output cell values.
For files emitted via the xlsx path, the locator points into the intermediate
CSV materialised during xlsx → CSV conversion.

When the GUI needs that detail (user clicks one row in the drill-down panel),
it:

1. Seeks the source CSV to `source_locator` and reads one record.
2. Calls the bridge's `eval_batch` op (in-process) with the row fields + the
   current config's `input_schema` and `row_rules` to recompute variable values,
   rule matches, and output cells.

This shifts the per-row eval cost from the trace producer to on-demand
consumption. Effects:

- Trace bytes shrink from O(rows × variables × bytes-per-trace-event) to
  O(rows × small header) — roughly two orders of magnitude on real
  workloads.
- Drill-down latency stays low for clicked rows (one re-eval ≈ 50 ms) and is
  paid only for rows the user actually opens.
- The current config is the source of truth at click time — drill-down
  reflects edits made after the trace was produced.

---

## Versioning policy

There is no in-band schema version. bxp-cli and bxp-gui are built and
released together from the same monorepo; a mismatched producer/consumer
pair is a build error, not a runtime concern.

Forward compatibility within one release line is provided by `pay_len`:
unknown frame types are skipped, and the frame layout uses fixed offsets
plus length-prefixed strings so adding optional payload fields requires a
new frame type (or a new release).
