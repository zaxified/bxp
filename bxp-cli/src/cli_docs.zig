//! Co-located documentation catalogs for bxp-cli's CLI surface: the flag table
//! (the `--help` renderer's source) and the process exit codes. Importable by
//! both `main.zig` (usage text) and the docs-md generator (reference Markdown),
//! so the help output and the docs page never drift.

/// One documented CLI flag. `arg` is the value placeholder (`""` = a boolean
/// flag that takes no value).
pub const FlagDoc = struct {
    flag: []const u8,
    arg: []const u8 = "",
    description: []const u8,
};

pub const flags = [_]FlagDoc{
    .{ .flag = "--config", .arg = "<path>", .description = "load custom config instead of default bxp-cli.json" },
    .{ .flag = "--template", .arg = "<id>", .description = "choose single template" },
    .{ .flag = "--data", .arg = "<path>", .description = "override templates's data_dir (requires --template)" },
    .{ .flag = "--fresh", .description = "skip files whose output already exists (atomic O_EXCL)" },
    .{ .flag = "--dry-run", .description = "run the pipeline in memory without writing output files (preview / validation); independent of --trace" },
    .{ .flag = "--trace", .description = "emit the binary BXTB trace stream on stdout, consumed by bxp-gui's dry-run debugger (forces --quiet; conflicts with --debug)" },
    .{ .flag = "--trace-file", .arg = "<path>", .description = "write a full binary trace (every row, every event) to <path>; independent of --trace; useful for offline GUI drill-down" },
    .{ .flag = "--debug", .description = "prints rows that match no rule as JSON on stdout when row_rules_debug_missing is set (conflicts with --quiet and --trace)" },
    .{ .flag = "--debug=json", .description = "emit ONE machine-readable JSON run summary on stdout (per-template + overall counts, captured warnings/errors) instead of human stdout+stderr output; conflicts with --trace/--quiet/--debug" },
    .{ .flag = "--quiet", .description = "suppress the informational stdout summaries (errors still go to stderr; the exit code still reflects the result)" },
    .{ .flag = "--check-fs", .arg = "<n>", .description = "opt-in: validate data_dir + input-file existence before any processing, with N-second total timeout (e.g. --check-fs 5). Default off." },
    .{ .flag = "--version", .description = "print version and exit" },
    .{ .flag = "--help", .description = "print this help and exit" },
};

/// One documented process exit code. Lives next to the exit-code precedence
/// logic in `main.zig run()`; the `--help` renderer is its consumer.
pub const ExitCodeDoc = struct {
    code: u8,
    meaning: []const u8,
};

pub const exit_codes = [_]ExitCodeDoc{
    .{ .code = 0, .meaning = "success" },
    .{ .code = 1, .meaning = "error" },
    .{ .code = 2, .meaning = "warnings" },
};
