# How-to Guides

## Adding a new conversion template

No code changes required — adding a broker is purely configuration work. The
full config schema, expression reference, and field-by-field walkthrough live
in the user-facing guide:

→ [`resources/readme.md`](https://github.com/zaxified/bxp/blob/master/resources/readme.md)

That document is what gets shipped inside `bxp-console` archives, so it
double-serves new contributors and end users. The short skeleton:

```json
"broker_to_tracker": {
  "data_dir":     "../data/broker_to_tracker",
  "file_pattern_in": ".csv",
  "input_schema": { "$date": "...", "$ticker": "...", /* ... */ },
  "row_rules":    [ { "when": "...", "rows": [ { "$action": "'BUY'" } ] } ],
  "output_schema": { "date": "$date", /* ... */ }
}
```

Dev-only tips (not in the user guide):

- Start with `row_rules_debug_missing: true` + run with `--debug` to surface
  rows that match no rule.
- For paired-row brokers (one row references another via an order ID),
  use `pre_pass` + `LOOKUP()`. AnyCoin is the reference template.
- Drop a `datasets/<template_id>/{sample.csv, sample.json, sample.expected}`
  triple to wire the template into the regression suite — `scripts/test.sh`
  picks it up automatically.

---

## Adding a new built-in function

1. **Define the function** in `bxp-core/src/expr.zig`:
   - Find the `evalFunc()` helper (called from the parser when a function name is recognized).
   - Add a new `if (std.mem.eql(u8, name, "MY_FUNC")) { ... }` branch.
   - Functions receive already-evaluated `Value` arguments.
   - Return a `Value` or propagate an error.

2. **Add a `FnDoc` entry** co-located with the implementation — follow the `── MY_FUNC ──`
   section-header pattern used by the existing built-ins. `docs.zig` re-exports the
   catalog automatically; no separate doc file to update.

3. **Add unit tests** inline in `expr.zig`:

   ```c
   test "MY_FUNC basic" {
       // ... uses std.testing.expectEqualStrings / expectApproxEqAbs
   }
   ```

4. **Run tests:**

   ```bash
   cd bxp-core && zig build test --summary all
   ```

---

## Adding a new bridge FFI export

The bridge hosts a **new-style FFI family** — synchronous, in-process C-ABI
exports that link a stateless `bxp-core` routine directly into the GUI process,
skipping the subprocess spawn. The first two members are `bridge_eval_expr`
(in-proc expr validation) and `bridge_eval_expr_trace` (in-proc expr
trace). The plan is to add more such direct calls once `bxp-core`'s
`inspect` surface stabilises and stops churning internally — every new
member follows the conventions below so adding the tenth export is as
mechanical as adding the first.

> These conventions cover the **stateless `bridge_eval_*` family only**. The
> legacy subprocess-proxy exports (`bridge_run`, `bridge_run_streaming`,
> `bridge_cancel`, `bridge_ack`, `bridge_free`) keep their own established
> conventions from the proxy era. A future **handle-based** family (stateful,
> e.g. a loaded-config handle) would need a separate convention set — lifecycle,
> per-handle memory, handle-table thread safety — deliberately out of scope here.

**1 — Buffer protocol.** Caller supplies the output buffer; the bridge never
`malloc`s the result and there is no Dart-side free for this family.

```zig
export fn bridge_eval_xxx(
    /* input params */
    out_buf: [*]u8, out_size: u32,
) callconv(.c) i32;
```

| Return | Meaning                                                                   |
| ------ | ------------------------------------------------------------------------- |
| `0`    | Success, no payload (valid, nothing to report)                            |
| `> 0`  | `bytes_written` to `out_buf` — may carry a success **or** failure payload |
| `< 0`  | Bridge-level error code (see rule 2)                                      |

A positive return does **not** automatically mean success: for exports where
error info belongs in the payload (`bridge_eval_expr` returns
`{"error":...,"off":...,"len":...}` JSON), the caller always parses `out_buf`
when `bytes_written > 0`. What a non-zero payload means is documented per-export
in its doc comment. On overflow the caller retries with a bigger buffer (4 KB
default for expr, 64 KB retry) — mirrors the `largeBufSize` retry in
`BridgeClient`.

**2 — Error codes.** Bridge-level failures (problems originating _in the bridge
layer_, not in evaluation) are a negative `i32` enum:

```zig
const BridgeFfiError = enum(i32) {
    out_of_memory = -1,   // c_allocator can't satisfy the per-call arena
    buf_too_small = -2,   // out_buf overflowed mid-write; caller retries bigger
    invalid_input = -3,   // caller's request is malformed: fix the call site
};
```

Note there is **no `eval_error` code**. Evaluation-level failures (syntax error,
unknown function, divide-by-zero) are _not_ a negative code — they return
`bytes_written > 0` with a structured JSON payload (rule 4). This was a
deliberate decision: keep negative codes for "your call is broken" and
let payloads carry "the expression is broken, show the user." Any new export
follows the same split.

**3 — Memory ownership: caller-owns-everything.** Input pointers are owned by
the caller for the call's duration; the bridge must hold no reference past
return. The output buffer is caller-allocated and caller-freed. Internally the
export opens a per-call `ArenaAllocator.init(c_allocator)` with `defer
arena.deinit()` — every transient allocation dies at return. No handle table,
no Dart-side `bridge_free` for this family.

**4 — Stateless + thread-safe.** Calling `bridge_eval_xxx(args)` 100× is
semantically identical to calling it once: no loaded configs, cached rows, or
counters survive between calls (the only allowed global is the read-only,
init-once docs catalog). Because there is no shared mutable state and the arena
is per-call, the family is thread-safe without mutexes — safe to call directly
from the Dart main isolate (sub-ms latency, well under one frame budget). If a
future export genuinely needs persistent state, it belongs in the handle-based
family, not here.

**5 — UTF-8, length-prefixed strings.** Inputs are `ptr: [*]const u8, len: u32`,
**not** null-terminated (`[*:0]`): Dart strings may contain interior `\0`, the
explicit length skips a `strlen`, and it stays consistent with the output buffer
protocol. JSON args (e.g. `row_headers` / `row_fields` for the trace export)
follow the same shape.

**6 — Output JSON shape matches the `inspect` core contract.** A failure payload is
byte-identical to the shape `inspect.validateExpr` produces (the same one bxp-mcp returns),
so the existing Dart parser handles bridge and subprocess responses
identically — no Dart parser change when wiring a new export:

```json
{"error":"<ErrorName>","detail":"<detail>","off":N,"len":N,"suggest":"..."}
```

`off` / `len` / `suggest` are optional (emitted only when the parser pins a token
or has a "did-you-mean" candidate). The trace export instead emits an NDJSON
stream identical to `inspect.evalTrace` output, where success/failure is read
from the `t` field of the last line.

**Worked reference — the shipped `bridge_eval_expr`:** see
[`bxp-gui-bridge/src/main.zig`](https://github.com/zaxified/bxp/blob/master/bxp-gui-bridge/src/main.zig) (`bridge_eval_expr`,
`writeExprErrorJson`, `writeStaticErrorJson`). Note it does two things beyond a
bare `expr.eval`: it runs `expr.staticCheckCalls` after a clean eval to catch
literal-only mistakes the runtime skips (e.g. `SPLIT_PART(..., 0)`), mirroring
`BrokerConfig.validate()` so editor-time and Save-time diagnostics agree. The
Dart side lives in
[`bxp-gui/lib/services/bridge_client.dart`](https://github.com/zaxified/bxp/blob/master/bxp-gui/lib/services/bridge_client.dart).

Any ABI change (signature, new error code) must bump both the bridge export and
its Dart shim in the **same commit** — there is no auto-versioned compatibility
shim, so a stale `.so`/`.dll` against a new GUI silently misbehaves.
