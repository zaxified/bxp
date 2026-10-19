# Zig pitfalls in this repository

Hard-won lessons from developing bxp on Zig 0.17. Each one cost a real bug or a
false-green check. Read before writing, reviewing or auditing Zig code here.
General Zig 0.17 API changes and gotchas live in the `zig-0.17` skill
(`.claude/skills/zig-0.17`, vendored from an audited release — never edit it here);
this file only holds what is specific to this repository.

## Language and std

- **`@intFromFloat` panics on NaN / ±Inf** (Debug and ReleaseSafe). A gate like
  `if (f < 1.0)` does not filter NaN (every NaN comparison is false). In
  `expr.zig`, turn a user float into a 1-based index with `toPositiveIndex`;
  for precision-style arguments gate with `std.math.isFinite` and clamp
  (`ROUND_MAX_PRECISION`) — a huge value is a hang, not only a panic.
- **`{d:0>4}` on a signed integer prints `+2024`.** A width/fill spec reserves a
  sign slot. Cast to unsigned before zero-padding (dates, fixed-width output).
- **`std.debug.print` writes to stderr.** Anything tooling captures (`--version`,
  `--help`, primary output) goes to stdout through a buffered writer + `flush`.
- **`return error.SkipZigTest` is runtime.** The test body is still analysed on
  every target, so a body that does not compile on Windows breaks the Windows
  build. Wrap it in a comptime-known `if (builtin.os.tag != .windows) { … }` —
  the doubled condition looks redundant and is not; do not "simplify" it.
- **Zig 0.17.0 miscompiles signed → narrower-unsigned casts (#37131).**
  `@intCast`, `std.math.cast`, `@max(0, x)` narrowing and `std.json` integer
  parsing into an unsigned type lower to `trunc nsw`: a value in the upper half
  of the destination range is poison in every optimized mode (the gate and the
  shipped ReleaseSmall), and a later check on it may be folded away. Debug is
  unaffected, so a Debug test proves nothing. Measured over every bxp root: no
  site where that changes behaviour — the reachable ones
  (`toPositiveIndex`, `header_row` / `csv_header_line` in `config.zig`, the
  bridge's `check_fs` timeout) only compare the result or turn it into `""`.
  They are left for 0.17.1, which carries the fix. Until then, write a new
  signed → unsigned narrowing in two steps (`std.math.cast(u64, x)` first, then
  the narrow cast) and test it in ReleaseSafe at the boundary value.

## Allocators

- **An `ArenaAllocator` makes `free` a no-op.** Handing an arena to code that
  frees per row / per item (e.g. `parseSheet`) accumulates a whole pass in RAM.
  Parallel workers take the same reclaiming allocator the serial path uses
  (`std.heap.smp_allocator` in release builds, see `bxp-cli/src/main.zig`); an
  arena is right only for code that streams and frees nothing.

## Verification traps (false greens)

- **`zig build-obj -target …` proves nothing about library code**: it analyses
  only what is reachable from exports. Use `zig test --test-no-exec -target …`,
  and run the check against the *unfixed* code first — if it passes there too,
  it is not a test.
- **Build mode matters for correctness, not only speed.** A bare `zig build` is
  Debug (except `bxp-cli`, whose `build.zig` defaults to ReleaseSafe). The bridge in Debug has stack frames big enough to overflow the Dart FFI
  thread (`0xc00000fd` on Windows). Smoke-test and measure with
  `-Doptimize=ReleaseSafe` — the whole `scripts/test.sh` runs in that one mode.
- **Datasets and the expression corpus can stay byte-identical over a broken
  per-row fast path.** Any optimisation in `expr.zig` (constant folding via
  `isRowInvariant`, compiled `Node` paths) must behave exactly like the fused
  `eval` / `evalFieldRef`: trim, `normalizeFieldDecimalSep`, and
  `canonicaliseNumericString` for string results. `isRowInvariant` is a
  blacklist — a new builtin that reads row state (fields, `FIELDS`, `LOOKUP`,
  `NOW`, `RAND`, `FILENAME`, `RECORD_NUM`, `SHEET_NAME`) must be added to it. Gate such
  changes with `test-09` (the examples), not only `test-06`/`test-07`.

## Build modes and backends here

Every compile step in all five `build.zig` files (`bxp-core`, `bxp-cli`, `bxp-mcp`,
`bxp-gui-bridge`, `tools/zig-doc-gen`) uses LLVM unless `-Dselfhosted=true` is passed.
The self-hosted backend is for the edit loop only; no gate and no CI lane uses it.
Each defect class is caught once, in the cheapest place:

| when | what to run |
|---|---|
| editing | whatever is fastest; `-Dselfhosted=true` is fine here |
| iterating on a fix | `zig build test` in the package you touched — LLVM Debug (`bxp-cli`: ReleaseSafe by default), `-Dtest-filter=` welcome |
| before ending work | the `scripts/test-NN-*.sh` phase(s) covering what you touched (ReleaseSafe). A change in `bxp-core` or the zig-libs pin reaches every package → `bash scripts/test.sh` |
| every package on three OSes | CI (`ci.yml`): the full `scripts/test.sh`, ReleaseSafe, on every PR and master push |
| the shipped mode | ReleaseSmall, built only by `scripts/release-0N-*.sh` |
| benchmarks, profiling, RSS | ReleaseFast / ReleaseSafe, never Debug (`file <bin>` before trusting a number) |

- `-Dselfhosted` is a per-package option: a downstream package never builds bxp-core's
  Compile steps, so it has to be passed to the package being built.
- There is no direct `zig test` / `zig build-exe` call in `scripts/`; a new one takes
  `-fllvm`.

## Repository conventions

- **Never run `zig fmt` on bxp sources.** Files carry deliberate manual column
  alignment; a blanket format produces hundreds of lines of noise. Match the
  surrounding alignment by hand; check `git diff --stat` stays proportional.
- **Subprocess tests use the repo's own helper binary**, never `/bin/true`,
  `/bin/sleep` or `cmd.exe`: see `bxp-gui-bridge/test/test_helper.zig` and the
  `test_helper_path` build option in `bxp-gui-bridge/build.zig`.
- **The error policy is template-strict, data-lenient** (root `CLAUDE.md` →
  Project rules): a crash is never acceptable, but fixing one keeps the silent
  `""` for runtime data rather than turning it into an error.
