/// Processing pipeline for bxp-cli: per-template file conversion and xlsx pre-pass.
///
/// Owns the core data-processing logic: reading input files, evaluating expressions,
/// applying row rules, and writing output.  CLI argument parsing and config loading
/// live in main.zig; all types that main.zig needs are exported as pub.

const std = @import("std");
const csv = @import("csv");
const config_mod = @import("config");
const expr_mod = @import("expr");
const xlsx_mod = @import("xlsx");
const json_mod = @import("json");

// 1 GiB cap. Whole-file load into RAM is the current design — streaming
// is roadmapped for v0.4.0. Until then this ceiling lets real-world public
// datasets (NYC Taxi monthly, NOAA GHCN per-station, Inside Airbnb city
// scrapes) fit, while still preventing runaway memory on pathological input.
const MAX_FILE_SIZE_BYTES: usize = 1024 * 1024 * 1024;
// Broker exports typically have 10–30 columns; real-world public datasets
// can reach 100+ (NOAA GHCN daily has 124, with paired measurement +
// quality-flag columns). 1024 is a generous ceiling that costs ~16 KB per
// file in arena-heap `hdr_buf` and ~16 KB per row in `row_buf`. Rows
// beyond this are truncated with a warning.
const MAX_COLUMNS: usize = 1024;
// One 64 KB write buffer per output file. Kept in the per-file stack frame;
// the OS then decides when to flush to disk. Smaller buffers cause noticeable
// syscall overhead on files with thousands of short rows.
const OUT_FILE_BUF_SIZE: usize = 65536;
// Stack buffer for decimal-separator substitution in writeSafeValue.
// Real numeric outputs are short ("123456789.12345678" = 18 chars); anything
// longer is treated as non-numeric and passed through verbatim.
const VAL_BUF_SIZE: usize = 64;
/// Runtime key for the date variable in the merged vars map (JSON5 converts @date → $date).
const VAR_DATE: []const u8 = "$date";

/// Writer abstraction used throughout the pipeline. Named for the role
/// (the **output file** the pipeline writes to), not the destination —
/// callers also pass a Discarding writer for `--dry-run`. Not stdout
/// despite the historic name. `pub` because main.zig wires it through.
pub const Writer = std.Io.Writer;

/// Accumulated warnings and errors for one processing section (xlsx preprocessing,
/// per-template processing, or overall).
pub const SectionStats = struct {
    warnings: u32 = 0,
    has_fatal: bool = false,
    /// Wall-clock nanoseconds elapsed during this section (set by the owning function).
    time_ns: u64 = 0,

    pub fn merge(self: *SectionStats, other: SectionStats) void {
        self.warnings += other.warnings;
        if (other.has_fatal) self.has_fatal = true;
        self.time_ns += other.time_ns;
    }
};

/// Trace verbosity mode for `--trace`. Today only `off` and `full` are
/// reachable from the CLI (`--trace` bool flag → `.full`); `.progress` and
/// `.detail` are scaffolding for a future PR that wires `--trace=MODE`
/// argument parsing and per-event filtering. Until then, `shouldEmit` treats
/// any non-`off` mode identically to `full`.
pub const TraceMode = enum(u2) { off, progress, detail, full };

/// Per-event emit filter — comptime-evaluated by callers in `event()`. The
/// truth table will be populated by the future selective-trace PR; for now
/// any non-`off` mode emits every event (preserving today's behaviour).
inline fn shouldEmit(mode: TraceMode, comptime t_name: []const u8) bool {
    _ = t_name;
    return mode != .off;
}

/// Output wrapper that suppresses all writes when --quiet or --trace is active.
/// All methods silently drop write errors (same pattern as existing debug prints).
/// When --trace is active, human-readable lines are suppressed so that stdout
/// contains only newline-delimited JSON (NDJSON) trace events.
pub const Output = struct {
    writer: *Writer,
    quiet: bool,
    debug: bool,
    trace: TraceMode = .off,
    dry_run: bool = false,

    /// True when any trace events are being emitted. Replaces the old
    /// `self.trace` bool reads — call sites must not compare the enum
    /// directly (a missing `.off` check would leak human-readable lines
    /// into the NDJSON stream and break the GUI parser).
    inline fn traceOn(self: Output) bool {
        return self.trace != .off;
    }

    /// Print an informational line. Suppressed in --quiet or --trace mode.
    pub fn info(self: Output, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet or self.traceOn()) return;
        self.writer.print(fmt, args) catch {};
        self.writer.flush() catch {};
    }

    /// Print a warning line. Suppressed in --quiet mode. Goes to stderr in
    /// every mode: in --trace mode stdout is reserved for the NDJSON event
    /// stream (interleaving raw text would break the GUI's line-by-line
    /// parser); in normal mode diagnostic output belongs on stderr per
    /// Unix convention so users redirecting stdout to a file don't get
    /// warnings inlined into their data.
    pub fn warning(self: Output, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet) return;
        std.debug.print(fmt, args);
    }

    /// Print a fatal-error line. Suppressed in --quiet mode. Goes to stderr
    /// for the same reasons as `warning` above — the GUI's NDJSON parser
    /// must see only events on stdout, and CLI users running e.g.
    /// `bxp-cli > out.csvx` need diagnostics out-of-band from the data.
    pub fn fatal(self: Output, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet) return;
        std.debug.print(fmt, args);
    }

    /// Print a per-section summary line. Suppressed in --quiet or --trace mode.
    pub fn summary(self: Output, stats: SectionStats) void {
        if (self.quiet or self.traceOn()) return;
        const errors: u32 = if (stats.has_fatal) 1 else 0;
        const secs = stats.time_ns / 1_000_000_000;
        const ms = (stats.time_ns % 1_000_000_000) / 1_000_000;
        self.writer.print("summary: errors:{d} warnings:{d} time:{d}.{d:0>3}s\n", .{ errors, stats.warnings, secs, ms }) catch {};
        self.writer.flush() catch {};
    }

    /// Print the overall summary line (no leading "summary:" label).
    /// Suppressed in --quiet or --trace mode.
    pub fn overallLine(self: Output, stats: SectionStats) void {
        if (self.quiet or self.traceOn()) return;
        const errors: u32 = if (stats.has_fatal) 1 else 0;
        const secs = stats.time_ns / 1_000_000_000;
        const ms = (stats.time_ns % 1_000_000_000) / 1_000_000;
        self.writer.print("errors:{d} warnings:{d} time:{d}.{d:0>3}s\n", .{ errors, stats.warnings, secs, ms }) catch {};
        self.writer.flush() catch {};
    }

    /// Emit one NDJSON event on stdout. No-op unless --trace is active.
    /// The caller provides an anonymous struct whose fields are merged into the event
    /// object alongside `"t": t_name`. `std.json.Stringify` handles string escaping.
    /// Errors are swallowed (same pattern as info/warning/fatal).
    pub fn event(self: Output, comptime t_name: []const u8, args: anytype) void {
        if (!self.traceOn()) return;
        if (!shouldEmit(self.trace, t_name)) return;
        var jw: std.json.Stringify = .{ .writer = self.writer, .options = .{} };
        jw.beginObject() catch return;
        jw.objectField("t") catch return;
        jw.write(t_name) catch return;
        inline for (std.meta.fields(@TypeOf(args))) |field| {
            jw.objectField(field.name) catch return;
            jw.write(@field(args, field.name)) catch return;
        }
        jw.endObject() catch return;
        self.writer.writeByte('\n') catch return;
        self.writer.flush() catch return;
    }
};

/// Returns true if s is a valid YYYY-MM-DD date string. Checks digit shape
/// AND component ranges (month 01–12, day 01–31). Rejects shapes like
/// `2026-13-99` so a malformed filename does not silently flip the row
/// filter into "min > max → drop everything" mode.
///
/// Note: day 31 is accepted for all months because tracking month lengths
/// (including leap years) would add complexity with no practical benefit —
/// broker filenames with day=32 or 99 are far more likely to be typos than
/// genuine February-31 dates.
fn isDate(s: []const u8) bool {
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    for (s[0..4]) |c| if (!std.ascii.isDigit(c)) return false;
    for (s[5..7]) |c| if (!std.ascii.isDigit(c)) return false;
    for (s[8..10]) |c| if (!std.ascii.isDigit(c)) return false;
    const month = (s[5] - '0') * 10 + (s[6] - '0');
    if (month < 1 or month > 12) return false;
    const day = (s[8] - '0') * 10 + (s[9] - '0');
    if (day < 1 or day > 31) return false;
    return true;
}

const DateRange = struct { min: []const u8, max: []const u8 };

const DateRangeResult = union(enum) {
    /// No `YYYY-MM-DD_YYYY-MM-DD` substring in the stem. This is documented
    /// behaviour: when `date_filter_from_filename` is on but the filename
    /// has no range, every row is processed unfiltered (test fixtures rely
    /// on this).
    none,
    /// A range was found but rejected: `min > max`, or one of the two dates
    /// has an out-of-range month/day. Caller should warn — silent
    /// `min > max` would filter every row out and produce empty output.
    invalid,
    /// Valid range; `min` <= `max` lexically (and therefore chronologically
    /// for ISO-8601 dates).
    valid: DateRange,
};

/// Returns true when `s` matches the digit/dash shape of a date but does
/// not necessarily have valid component values. Used to distinguish "user
/// clearly tried to put a range here but typo'd" (.invalid) from "no
/// range present at all" (.none).
fn isDateShape(s: []const u8) bool {
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    for (s[0..4]) |c| if (!std.ascii.isDigit(c)) return false;
    for (s[5..7]) |c| if (!std.ascii.isDigit(c)) return false;
    for (s[8..10]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Searches for "YYYY-MM-DD_YYYY-MM-DD" anywhere in the file stem (without
/// extension). Returns slices into stem — no allocation.
fn extractDateRange(stem: []const u8) DateRangeResult {
    if (stem.len < 21) return .none;
    var i: usize = 0;
    while (i + 21 <= stem.len) : (i += 1) {
        const s = stem[i..];
        // Pass 1: full validation (component ranges checked too).
        if (isDate(s[0..10]) and s[10] == '_' and isDate(s[11..21])) {
            const min = s[0..10];
            const max = s[11..21];
            if (std.mem.order(u8, min, max) == .gt) return .invalid;
            return .{ .valid = .{ .min = min, .max = max } };
        }
        // Pass 2: shape-only match. A `\d{4}-\d{2}-\d{2}_\d{4}-\d{2}-\d{2}`
        // pattern with invalid components (e.g. `2026-13-99`) is almost
        // certainly an intended-but-typo'd range, not random data — flag
        // it so silent filter-by-no-range doesn't drop every row.
        if (isDateShape(s[0..10]) and s[10] == '_' and isDateShape(s[11..21])) {
            return .invalid;
        }
    }
    return .none;
}

/// Substring scan for `LOOKUP(` across every expression string in a
/// BrokerConfig (input_schema vars, row_rules `when`, row_rules rows
/// overrides). Used to decide whether the LOOKUP-without-pre_pass
/// warning should fire for the template. Conservative: accepts false
/// positives on string literals containing "LOOKUP(" — the warning is
/// corrective either way.
///
/// pre_pass.values expressions are intentionally excluded: they cannot
/// contain LOOKUP() calls (the pre_pass evaluation context has no
/// lookup_table pointer — self-referential pre_pass is undefined).
fn configMentionsLookup(bc: *const config_mod.BrokerConfig) bool {
    // StringArrayHashMap exposes values as a slice; iterate by reference
    // so the substring scan operates on stable pointers.
    for (bc.input_schema.values()) |expr| {
        if (std.mem.indexOf(u8, expr, "LOOKUP(") != null) return true;
    }
    if (bc.row_rules) |rules| {
        for (rules) |rule| {
            if (std.mem.indexOf(u8, rule.when, "LOOKUP(") != null) return true;
            for (rule.rows) |row| {
                var row_it = row.valueIterator();
                while (row_it.next()) |expr| {
                    if (std.mem.indexOf(u8, expr.*, "LOOKUP(") != null) return true;
                }
            }
        }
    }
    return false;
}

/// Returns true when s is a plain decimal number: optional '-', digits,
/// optional '.' followed by more digits — nothing else.
fn isNumericValue(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[i] == '-') i += 1;
    if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    return i == s.len;
}

/// Writes value to out.
///
/// When quote_out != 0 and the value contains the output delimiter, the quote
/// character, \r, or \n, the value is wrapped in quote_out characters and any
/// internal occurrences of quote_out are doubled (RFC 4180 §2.5–2.7).
///
/// When no quoting is applied: values starting with a spreadsheet formula
/// character ('=', '+', '-', '@') get a leading single-quote to neutralise
/// injection; embedded \n is replaced with the literal two-char sequence \n;
/// \r bytes are dropped.
///
/// When decimal_sep_out != '.', numeric values have their '.' replaced with
/// decimal_sep_out before writing.
fn writeSafeValue(out: *Writer, value: []const u8, delimiter_out: u8, decimal_sep_out: u8, quote_out: u8, buf: []u8) !void {
    // Apply decimal separator conversion for numeric output values.
    //
    // Values longer than `buf.len` (VAL_BUF_SIZE = 64) are passed through
    // unchanged when a non-default decimal separator is configured —
    // intentional: real numeric outputs are short ("123456.78"), and
    // anything longer is either non-numeric (caught by isNumericValue) or
    // a malformed value that the user should see verbatim. If a caller
    // ever needs > 64-char numeric conversion, switch to a heap buffer
    // sourced from `line_alloc`.
    const s = blk: {
        if (decimal_sep_out != '.' and value.len <= buf.len and isNumericValue(value)) {
            @memcpy(buf[0..value.len], value);
            std.mem.replaceScalar(u8, buf[0..value.len], '.', decimal_sep_out);
            break :blk buf[0..value.len];
        }
        break :blk value;
    };
    // RFC 4180 output quoting: wrap when value contains the delimiter, the
    // quote character, CR, or LF.  Internal quote chars are doubled.
    // Pre-quoted pass-through: a value that already starts and ends with quote_out
    // (produced by ''' expressions) is written with its outer quotes preserved and
    // any internal occurrences of quote_out doubled (RFC 4180 §2.5).
    if (quote_out != 0 and s.len >= 2 and s[0] == quote_out and s[s.len - 1] == quote_out) {
        try out.writeByte(quote_out);
        for (s[1 .. s.len - 1]) |ch| {
            if (ch == quote_out) try out.writeByte(quote_out);
            try out.writeByte(ch);
        }
        try out.writeByte(quote_out);
        return;
    }
    if (quote_out != 0) {
        var needs_quote = false;
        for (s) |ch| {
            if (ch == delimiter_out or ch == quote_out or ch == '\r' or ch == '\n') {
                needs_quote = true;
                break;
            }
        }
        if (needs_quote) {
            try out.writeByte(quote_out);
            for (s) |ch| {
                if (ch == quote_out) try out.writeByte(quote_out); // escape: double it
                try out.writeByte(ch);
            }
            try out.writeByte(quote_out);
            return;
        }
    }
    // No quoting applied: formula-injection prefix + \n→\n literal replacement.
    // Tab (`\t`) is also a known Excel/LibreOffice formula trigger when the
    // cell parser hits it on the leading edge — broker exports rarely emit
    // a tab-leading value but the prefix is cheap insurance.
    //
    // '-' is special: a leading minus is valid for negative numbers (e.g.
    // "-12.34") and must NOT be prefixed — that would produce "'-12.34",
    // which would then parse as a string in the portfolio tracker. Only
    // prefix when '-' is followed by a non-digit (e.g. "-- comment"),
    // which is an injection pattern, not a number.
    if (s.len > 0) {
        switch (s[0]) {
            '=', '+', '@', '\t' => try out.writeByte('\''),
            '-' => {
                const next_is_numeric = s.len > 1 and
                    (std.ascii.isDigit(s[1]) or s[1] == decimal_sep_out);
                if (!next_is_numeric) try out.writeByte('\'');
            },
            else => {},
        }
    }
    for (s) |ch| {
        switch (ch) {
            '\n' => try out.writeAll("\\n"),
            '\r' => {},
            else => try out.writeByte(ch),
        }
    }
}

/// Writes a JSON object row to out.
/// Format: {"col1":"val1","col2":"val2",...}
/// All values are emitted as JSON strings.  Special characters are escaped.
fn writeJsonRow(
    out: *Writer,
    columns: []const config_mod.OutputColumn,
    vars: *const std.StringHashMap([]const u8),
) !void {
    try out.writeByte('{');
    for (columns, 0..) |col, ci| {
        if (ci > 0) try out.writeByte(',');
        try out.writeByte('"');
        try writeJsonString(out, col.header);
        try out.writeAll("\":\"");
        try writeJsonString(out, vars.get(col.variable) orelse "");
        try out.writeByte('"');
    }
    try out.writeByte('}');
}

/// Writes s to out with JSON string escaping (RFC 8259 §7).
fn writeJsonString(out: *Writer, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            // Other C0 control characters (excluding \n=0x0a, \r=0x0d, \t=0x09):
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var buf: [6]u8 = undefined;
                const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{@as(u32, ch)}) catch unreachable; // buf is [6]u8; "\uXXXX" is always 6 bytes
                try out.writeAll(esc);
            },
            else => try out.writeByte(ch),
        }
    }
}

/// Evaluates all input_schema expressions for the current row into a variable map.
/// Keys are variable names (owned by config); values are allocated with ctx.alloc.
/// On expression error the variable is stored as empty string and `error_count`
/// is incremented — the caller bumps `stats.warnings` once per file when the
/// counter exceeds zero, so silent expression failures still flip the binary's
/// exit code to 2 and surface in the summary.
/// In debug mode, every error is printed before being suppressed.
/// Saves and restores ctx.error_detail so the caller's detail buffer is unaffected.
fn evalAllVars(
    schema: std.StringArrayHashMap([]const u8),
    ctx: *expr_mod.Context,
    out: Output,
    error_count: *u32,
) !std.StringHashMap([]const u8) {
    var vars = std.StringHashMap([]const u8).init(ctx.alloc);
    var detail: []const u8 = "";
    const saved_detail = ctx.error_detail;
    ctx.error_detail = &detail;
    defer ctx.error_detail = saved_detail;
    var it = schema.iterator();
    while (it.next()) |e| {
        detail = "";
        const val = expr_mod.evalString(e.value_ptr.*, ctx) catch |err| blk: {
            error_count.* += 1;
            if (out.debug) {
                if (detail.len > 0) {
                    out.writer.print("[expr error] {s} = \"{s}\": {s} ({s})\n  fields:", .{ e.key_ptr.*, e.value_ptr.*, @errorName(err), detail }) catch {};
                } else {
                    out.writer.print("[expr error] {s} = \"{s}\": {s}\n  fields:", .{ e.key_ptr.*, e.value_ptr.*, @errorName(err) }) catch {};
                }
                for (ctx.fields) |f| {
                    out.writer.print(" \"{s}\"", .{f}) catch {};
                }
                out.writer.print("\n", .{}) catch {};
                out.writer.flush() catch {};
            }
            out.event("var_error", .{ .name = e.key_ptr.*, .expr = e.value_ptr.*, .@"error" = @errorName(err), .detail = detail, .origin = "input_schema" });
            break :blk "";
        };
        out.event("var_eval", .{ .name = e.key_ptr.*, .expr = e.value_ptr.*, .value = val, .origin = "input_schema" });
        try vars.put(e.key_ptr.*, val);
    }
    return vars;
}

/// Phase G2: walk every `[FieldName]` reference in this broker's
/// expressions (input_schema + row_rules + pre_passes) and check it
/// against the actual file header in `col_index`. Returns true when
/// at least one warning was emitted — caller bumps `stats.warnings`
/// once for the file and continues processing (silent fallback "" is
/// preserved at runtime).
///
/// Filter: only flag a missing `[X]` when its Levenshtein distance to
/// some real header is ≤ 2. High-distance mismatches are treated as
/// legitimate optional / cross-version columns (e.g. Trading 212's
/// `[Stamp duty reserve tax]` against an older CSV that lacks the
/// column — gateted by `IF([X] > 0, ...)` and falling back to "" by
/// design).
fn checkUnknownFields(
    bc: *const config_mod.BrokerConfig,
    col_index: *const std.StringHashMap(usize),
    alloc: std.mem.Allocator,
    out: Output,
    filename: []const u8,
) !bool {
    // Per-broker arena so transient hash sets in `staticReferences`
    // free in one shot.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const Match = struct { bad: []const u8, suggest: []const u8 };

    // Walks one expression. Returns the first `[X]` reference whose
    // Levenshtein distance to some real header is ≤ 2 — that's the
    // typo class. Mismatches with no close header (distance ≥ 3) are
    // skipped: legitimate optional / cross-version columns. Numeric
    // `[1]` indexes are already filtered by `staticReferences`.
    const inner = struct {
        fn check(
            ar_: std.mem.Allocator,
            ci: *const std.StringHashMap(usize),
            src: []const u8,
        ) !?Match {
            if (src.len == 0) return null;
            var refs = try expr_mod.staticReferences(src, ar_);
            defer refs.deinit();
            var it = refs.fields.iterator();
            while (it.next()) |e| {
                const name = e.key_ptr.*;
                if (ci.contains(name)) continue;
                // Find closest real header. Only treat as a typo when
                // distance ≤ 2; otherwise the user almost certainly
                // meant a column that genuinely isn't present in this
                // file (silent fallback is appropriate).
                var best: ?[]const u8 = null;
                var best_d: usize = std.math.maxInt(usize);
                var ci_it = ci.iterator();
                while (ci_it.next()) |ce| {
                    const d = config_mod.levenshteinIgnoreCase(name, ce.key_ptr.*);
                    if (d < best_d) {
                        best_d = d;
                        best = ce.key_ptr.*;
                    }
                }
                // Length-relative threshold — at 4 chars, dist 2 means
                // half the word differs (`Time` vs `Type`), which is
                // more likely a different column than a typo. Mirror
                // the load-time `staticCheckFieldClustering` gate.
                const max_d: usize = if (name.len < 6) 1 else 2;
                if (best != null and best_d <= max_d) {
                    return .{ .bad = name, .suggest = best.? };
                }
            }
            return null;
        }
    }.check;

    const emit = struct {
        fn fire(
            o: Output,
            fname: []const u8,
            where: []const u8,
            m: Match,
        ) void {
            o.warning(
                "warning: unknown field '{s}' referenced in {s} of '{s}' — did you mean '{s}'?\n",
                .{ m.bad, where, fname, m.suggest },
            );
        }
    }.fire;

    // Caller uses the bool return purely as "did we emit any warning"
    // so `stats.warnings` ticks once per file regardless of how many
    // typos we surface. We therefore walk every section to fullness —
    // a user fixing 5 typos sees them all in one run instead of one
    // round-trip per fix. `inner` returns the FIRST typo per
    // expression; multi-typo expressions still need a re-run, but
    // that's a single expression, not a single section.
    var any = false;

    // input_schema
    var is_it = bc.input_schema.iterator();
    while (is_it.next()) |entry| {
        if (try inner(ar, col_index, entry.value_ptr.*)) |m| {
            emit(out, filename, "input_schema", m);
            any = true;
        }
    }

    // row_rules.when + row_rules.rows[].$var
    if (bc.row_rules) |rules| {
        for (rules) |rule| {
            if (try inner(ar, col_index, rule.when)) |m| {
                emit(out, filename, "row_rules.when", m);
                any = true;
            }
            for (rule.rows) |row| {
                var ov = row.iterator();
                while (ov.next()) |o| {
                    if (try inner(ar, col_index, o.value_ptr.*)) |m| {
                        emit(out, filename, "row_rules override", m);
                        any = true;
                    }
                }
            }
        }
    }

    // pre_passes[name].when / key / values
    var pp_it = bc.pre_passes.iterator();
    while (pp_it.next()) |pp_entry| {
        const pp = pp_entry.value_ptr.*;
        if (try inner(ar, col_index, pp.when)) |m| {
            emit(out, filename, "pre_pass.when", m);
            any = true;
        }
        if (try inner(ar, col_index, pp.key)) |m| {
            emit(out, filename, "pre_pass.key", m);
            any = true;
        }
        var v_it = pp.values.iterator();
        while (v_it.next()) |v| {
            if (try inner(ar, col_index, v.value_ptr.*)) |m| {
                emit(out, filename, "pre_pass.values", m);
                any = true;
            }
        }
    }

    return any;
}

// ── Streaming CSV reader (10 MiB chunks) ───────────────────────────────
//
// `processBroker` streams CSV input in CHUNK_SIZE blocks and resets a
// dedicated per-chunk arena between blocks so peak memory is bounded by
// the chunk size — not by the file size. Quoted multi-line fields are
// respected: chunk boundaries always land on a '\n' that occurs
// OUTSIDE a quoted field, mirroring `csv.splitRecords()` semantics.

/// Target chunk size in bytes. The buffer may grow above this when a
/// single record is longer than CHUNK_SIZE (no '\n' outside quotes
/// within the chunk window).
const CHUNK_SIZE: usize = 10 * 1024 * 1024;

/// Scans bytes tracking RFC-4180 quote state; returns the index of the
/// LAST '\n' that occurs OUTSIDE a quoted field, or null if no such
/// boundary exists. Mirrors the in_quotes logic in `csv.splitRecords`.
fn findLastBoundary(bytes: []const u8, quote: u8) ?usize {
    var pos: usize = 0;
    var in_quotes: bool = false;
    var last_nl: ?usize = null;
    while (pos < bytes.len) {
        const c = bytes[pos];
        if (quote != 0 and c == quote) {
            if (in_quotes and pos + 1 < bytes.len and bytes[pos + 1] == quote) {
                pos += 2;
                continue;
            }
            in_quotes = !in_quotes;
            pos += 1;
        } else if (c == '\n' and !in_quotes) {
            last_nl = pos;
            pos += 1;
        } else {
            pos += 1;
        }
    }
    return last_nl;
}

/// Streaming file reader that yields chunks ending on record boundaries.
/// Owns a backing `buffer` that holds residual bytes between calls.
/// The slice returned by `nextChunk` is valid only until the next call.
const ChunkReader = struct {
    file: std.fs.File,
    quote: u8,
    buffer: std.array_list.Managed(u8),
    /// Number of bytes returned by the previous nextChunk() call. Those
    /// bytes are discarded from the front of `buffer` at the start of the
    /// next call so only residual remains.
    last_emit_len: usize,
    /// Total file size (from stat at init); used to right-size the buffer
    /// so files smaller than CHUNK_SIZE do not pay for a 10 MiB allocation.
    total_size: u64,
    bytes_read: u64,
    eof: bool,

    pub fn init(alloc: std.mem.Allocator, file: std.fs.File, quote: u8) !ChunkReader {
        const stat = try file.stat();
        return .{
            .file = file,
            .quote = quote,
            .buffer = std.array_list.Managed(u8).init(alloc),
            .last_emit_len = 0,
            .total_size = stat.size,
            .bytes_read = 0,
            .eof = false,
        };
    }

    pub fn deinit(self: *ChunkReader) void {
        self.buffer.deinit();
    }

    /// Returns the next chunk of bytes ending at a record boundary
    /// (the last '\n' outside a quoted field). At EOF, returns the
    /// remaining bytes verbatim. Returns null when nothing is left.
    pub fn nextChunk(self: *ChunkReader) !?[]const u8 {
        // Drop bytes returned by the previous call so only residual remains.
        if (self.last_emit_len > 0) {
            const tail_len = self.buffer.items.len - self.last_emit_len;
            if (tail_len > 0) {
                std.mem.copyForwards(
                    u8,
                    self.buffer.items[0..tail_len],
                    self.buffer.items[self.last_emit_len..],
                );
            }
            self.buffer.items.len = tail_len;
            self.last_emit_len = 0;
        }
        while (true) {
            if (findLastBoundary(self.buffer.items, self.quote)) |boundary| {
                self.last_emit_len = boundary + 1;
                return self.buffer.items[0..self.last_emit_len];
            }
            if (self.eof) {
                if (self.buffer.items.len == 0) return null;
                self.last_emit_len = self.buffer.items.len;
                return self.buffer.items;
            }
            // Right-size the next read: never reserve more than what the
            // file still has to offer. For a 281 KB file this caps the
            // buffer at 281 KB instead of 10 MiB; for a 100 MiB file it
            // still grants the full 10 MiB chunk after each rotation.
            const remaining: u64 = if (self.bytes_read >= self.total_size)
                0
            else
                self.total_size - self.bytes_read;
            if (remaining == 0) {
                self.eof = true;
                continue;
            }
            const want_cap: usize = @intCast(@min(@as(u64, CHUNK_SIZE), remaining));
            try self.buffer.ensureUnusedCapacity(want_cap);
            const dest = self.buffer.unusedCapacitySlice();
            const want = @min(dest.len, want_cap);
            const n = try self.file.read(dest[0..want]);
            self.buffer.items.len += n;
            self.bytes_read += n;
            if (n == 0) self.eof = true;
        }
    }
};

/// Unified row producer for the main pipeline loop.
///
/// CSV path → wraps a streaming `RowIterator`. Returned fields slices
///            live in chunk_arena and become invalid on next call.
/// JSON path → wraps the pre-materialised `all_rows` slice from
///             `json_mod.readJsonRecords`. Slices live in file_alloc
///             and remain valid for the whole file.
///
/// Both variants satisfy the single `next()` contract used by the main
/// loop, so the row body is written once.
const RowSource = union(enum) {
    json_materialised: struct {
        rows: [][][]const u8,
        idx: usize,
    },
    csv_streaming: *RowIterator,

    pub fn next(self: *RowSource) !?[][]const u8 {
        switch (self.*) {
            .json_materialised => |*j| {
                if (j.idx >= j.rows.len) return null;
                const f = j.rows[j.idx];
                j.idx += 1;
                return f;
            },
            .csv_streaming => |iter| return try iter.next(),
        }
    }
};

/// Iterator that produces parsed CSV row fields by reading chunks from a
/// `ChunkReader` and splitting records via `csv.splitRecords`/`splitFields`.
///
/// `chunk_arena` is reset on each chunk boundary; the returned fields
/// slice (and the string slices inside it) are valid only until the
/// next call to `next()` or `parseHeader()`. Caller must dupe out any
/// data that needs to outlive the current row.
const RowIterator = struct {
    reader: *ChunkReader,
    chunk_arena: *std.heap.ArenaAllocator,
    delimiter: u8,
    quote: u8,

    /// Current chunk's records (slices into reader.buffer). Replaced on
    /// each chunk transition; backed by chunk_arena.
    records: std.array_list.Managed([]const u8),
    rec_idx: usize,
    header_consumed: bool,
    /// Reusable per-row slice buffer. Lives in file_alloc (not chunk_arena)
    /// so it survives chunk resets; allocated once at init. Caller already
    /// must dupe out any data needed past the next `next()` / `parseHeader()`
    /// call, so reusing the same buffer across rows is safe.
    row_buf: [][]const u8,

    pub fn init(
        reader: *ChunkReader,
        chunk_arena: *std.heap.ArenaAllocator,
        file_alloc: std.mem.Allocator,
        delimiter: u8,
        quote: u8,
    ) !RowIterator {
        return .{
            .reader = reader,
            .chunk_arena = chunk_arena,
            .delimiter = delimiter,
            .quote = quote,
            .records = std.array_list.Managed([]const u8).init(chunk_arena.allocator()),
            .rec_idx = 0,
            .header_consumed = false,
            .row_buf = try file_alloc.alloc([]const u8, MAX_COLUMNS),
        };
    }

    /// Parses the header record from the first chunk. Returned slice and
    /// its string contents live in chunk_arena — caller MUST dupe them
    /// out into a longer-lived allocator before calling next().
    ///
    /// On the first chunk, BOM (EF BB BF) is stripped before parsing.
    ///
    /// Returns an empty slice when the file has no records at all.
    pub fn parseHeader(self: *RowIterator) ![][]const u8 {
        if (self.header_consumed) return &.{};
        var chunk_bytes = (try self.reader.nextChunk()) orelse {
            self.header_consumed = true;
            return &.{};
        };
        // BOM strip (only meaningful on the first chunk; subsequent
        // chunks never start with BOM).
        if (chunk_bytes.len >= 3 and std.mem.eql(u8, chunk_bytes[0..3], "\xEF\xBB\xBF")) {
            chunk_bytes = chunk_bytes[3..];
        }
        _ = self.chunk_arena.reset(.retain_capacity);
        self.records = try csv.splitRecords(chunk_bytes, self.quote, self.chunk_arena.allocator());
        self.rec_idx = 0;
        self.header_consumed = true;
        if (self.records.items.len == 0) return &.{};
        const hdr_buf = try self.chunk_arena.allocator().alloc([]const u8, MAX_COLUMNS + 1);
        const header = try csv.splitFields(
            self.records.items[0], hdr_buf,
            self.delimiter, self.quote, self.chunk_arena.allocator(),
        );
        self.rec_idx = 1;
        return header;
    }

    /// Returns next row fields, or null at EOF. Must be called only
    /// AFTER `parseHeader()` (which primes the iterator on the first
    /// chunk). Slice + strings inside are valid until the next call.
    pub fn next(self: *RowIterator) !?[][]const u8 {
        while (true) {
            if (self.rec_idx < self.records.items.len) {
                const rec = self.records.items[self.rec_idx];
                self.rec_idx += 1;
                return try csv.splitFields(
                    rec, self.row_buf, self.delimiter, self.quote, self.chunk_arena.allocator(),
                );
            }
            const chunk_bytes = (try self.reader.nextChunk()) orelse return null;
            _ = self.chunk_arena.reset(.retain_capacity);
            self.records = try csv.splitRecords(chunk_bytes, self.quote, self.chunk_arena.allocator());
            self.rec_idx = 0;
        }
    }
};

/// Evaluates every configured pre_pass block against one input row,
/// inserting matching results into `lookup_table`. Strings written to
/// the table allocate from `file_alloc` so they persist for the whole
/// file (the chunk arena is reset between chunks).
///
/// Errors during expression evaluation are swallowed silently — same
/// behaviour as the legacy whole-file pre_pass loop — and logged when
/// --debug is on. Empty key values cause the row to be skipped.
fn evalPrepassRow(
    fields: [][]const u8,
    col_index: *const std.StringHashMap(usize),
    lookup_table: *std.StringHashMap([]const u8),
    bc: *const config_mod.BrokerConfig,
    file_alloc: std.mem.Allocator,
    out: Output,
) !void {
    const pre_ctx = expr_mod.Context{
        .fields = fields,
        .col_index = col_index,
        .quote_out = bc.csv_text_quote_out,
        .ticker_map = &bc.ticker_map,
        .lookup_table = null, // no self-reference during pre_pass
        .alloc = file_alloc,
        .decimal_sep_in = bc.csv_decimal_separator_in,
    };
    var pp_it = bc.pre_passes.iterator();
    while (pp_it.next()) |pp_entry| {
        const pp_name = pp_entry.key_ptr.*;
        const pp = pp_entry.value_ptr.*;
        const when = expr_mod.eval(pp.when, &pre_ctx) catch |err| {
            if (out.debug) {
                out.writer.print("[pre_pass {s} error] when = \"{s}\": {s}\n", .{ pp_name, pp.when, @errorName(err) }) catch {};
                out.writer.flush() catch {};
            }
            continue;
        };
        if (!when.toBool()) continue;
        const key_val = expr_mod.evalString(pp.key, &pre_ctx) catch |err| {
            if (out.debug) {
                out.writer.print("[pre_pass {s} error] key = \"{s}\": {s}\n", .{ pp_name, pp.key, @errorName(err) }) catch {};
                out.writer.flush() catch {};
            }
            continue;
        };
        if (key_val.len == 0) continue;
        // `key_val` is dupe'd implicitly via the composite-key concat
        // below (std.mem.concat copies bytes into file_alloc).
        var v_it = pp.values.iterator();
        while (v_it.next()) |ve| {
            const val_raw = expr_mod.evalString(ve.value_ptr.*, &pre_ctx) catch |err| {
                if (out.debug) {
                    out.writer.print("[pre_pass {s} error] values.{s} = \"{s}\": {s}\n", .{ pp_name, ve.key_ptr.*, ve.value_ptr.*, @errorName(err) }) catch {};
                    out.writer.flush() catch {};
                }
                continue;
            };
            // evalString may return a slice that points back into the
            // input field bytes (for trivial expressions like a direct
            // `[Column]` reference). Under chunked streaming those bytes
            // live in chunk_arena and become invalid on the next chunk
            // — so dupe into file_alloc to outlive the chunk.
            const val = try file_alloc.dupe(u8, val_raw);
            const composite = try std.mem.concat(file_alloc, u8, &.{ pp_name, "\x00", key_val, "\x00", ve.key_ptr.* });
            try lookup_table.put(composite, val);
            out.event("prepass_set", .{ .name = pp_name, .key = key_val, .field = ve.key_ptr.*, .value = val });
        }
    }
}

/// Processes all matching input files in dir_path for the given template.
/// For each file:
///   1. Extracts optional date range from the filename.
///   2. Streams the input (CSV or JSON) in 10 MiB chunks; builds col_index from the header/keys.
///   3. Builds pre_pass lookup table if configured (streaming first pass over the file).
///   4. Evaluates input_schema expressions per row and writes output (CSV or JSON).
/// Returns accumulated SectionStats for this template.
pub fn processBroker(
    bid: []const u8,
    dir_path: []const u8,
    bc: *const config_mod.BrokerConfig,
    fresh: bool,
    out: Output,
    alloc: std.mem.Allocator,
) !SectionStats {
    var stats = SectionStats{};
    var timer = try std.time.Timer.start();

    out.info("\n=== template: {s} ===\n", .{bid});

    // LOOKUP-without-pre_pass guard: bxp-fmt --config catches this at
    // validate time, but a hot-swapped config skips that gate. Warn once
    // per template so the silent runtime symptom (LOOKUP returning "")
    // surfaces. Substring scan accepts false positives on string-literal
    // mentions of "LOOKUP(" — acceptable, the warning text is corrective
    // ("define a pre_pass or remove LOOKUP usage") regardless.
    if (bc.pre_passes.count() == 0 and configMentionsLookup(bc)) {
        out.warning("warning: template '{s}' uses LOOKUP() but has no pre_pass blocks defined; LOOKUP calls will silently return \"\"\n", .{bid});
        stats.warnings += 1;
    }

    // Open the data directory; print a clean message if it doesn't exist.
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            out.fatal("error: directory not found: '{s}'\n", .{dir_path});
            stats.has_fatal = true;
            stats.time_ns = timer.read();
            return stats;
        }
        return err;
    };
    defer dir.close();

    // Collect all matching filenames into a sorted list before opening any
    // output files. This avoids re-entrancy issues with the directory
    // iterator (creating output files in the same directory while iterating
    // is undefined on some platforms), and also gives us a deterministic
    // processing order independent of the underlying filesystem's readdir
    // ordering (which is inode-order on ext4, insertion-order on FAT, etc.).
    const csv_suffix: []const u8 = bc.file_pattern_in;
    var names = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit();
    }
    {
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, entry.name, csv_suffix)) continue;
            try names.append(try alloc.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    if (names.items.len == 0) {
        out.info("No input files for template '{s}' in '{s}'\n", .{ bid, dir_path });
        stats.time_ns = timer.read();
        return stats;
    }

    // ── Combined-output mode setup ─────────────────────────────────────
    // When `combined_output: true`, every input file in this template
    // ADDITIONALLY appends to ONE shared sink (file or discarding under
    // --dry-run) alongside its normal per-file output. Header is emitted
    // once before the loop; the file stays open through every iteration
    // and is closed/flushed after the loop. The per-file `.csvx` outputs
    // continue to be produced unchanged — combined is an extra artefact,
    // not a replacement.
    const combined = bc.combined_output;
    var combined_out_name_owned: ?[]u8 = null;
    defer if (combined_out_name_owned) |s| alloc.free(s);
    var combined_out_file: std.fs.File = undefined;
    var combined_out_file_buf: [OUT_FILE_BUF_SIZE]u8 = undefined;
    var combined_out_fw: std.fs.File.Writer = undefined;
    // Initialise to a Discarding writer up-front so a stray flush at
    // teardown is harmless even if no real combined sink was ever opened.
    // The `combined_file_opened` flag still gates the meaningful flush
    // path, but losing that invariant no longer reads undefined memory.
    var combined_discarding: std.Io.Writer.Discarding = .init(&combined_out_file_buf);
    var combined_fout: *std.Io.Writer = &combined_discarding.writer;
    var combined_json_first_row: bool = true;
    var combined_file_opened = false;
    // True once --fresh confirmed the combined file already exists and
    // routed the combined sink into a Discarding writer. Used inside the
    // per-file loop to decide whether to skip an input file outright
    // (both sinks are no-op) or still iterate it so the active sink
    // (per-file OR combined) gets rows.
    var combined_skipped = false;
    defer if (combined_file_opened and !out.dry_run) combined_out_file.close();

    if (combined) {
        // Filename convention: `1-{template_id}-combined{file_pattern_out}`.
        // The leading `1-` sorts the combined output before per-template
        // alphabetic neighbours in `ls` (matches operator expectation for
        // "rolled-up" artefacts). file_pattern_out (e.g. ".csvx") supplies
        // the extension; when empty, fall back to "x" mirroring the
        // per-file fallback at the bottom of this loop.
        const suffix = if (bc.file_pattern_out.len > 0) bc.file_pattern_out else "x";
        combined_out_name_owned = try std.fmt.allocPrint(
            alloc, "1-{s}-combined{s}", .{ bid, suffix });
        const combined_out_name = combined_out_name_owned.?;

        if (out.dry_run) {
            // combined_fout already points at combined_discarding from
            // the top-of-function init; no rewiring needed.
        } else if (fresh) {
            // --fresh + combined: O_EXCL create the combined sink. If it
            // exists, fall through to discarding so the per-file outputs
            // (which still honour their own --fresh skip) are unaffected.
            if (dir.createFile(combined_out_name, .{ .exclusive = true })) |f| {
                combined_out_file = f;
                combined_file_opened = true;
                combined_out_fw = combined_out_file.writer(&combined_out_file_buf);
                combined_fout = &combined_out_fw.interface;
            } else |e| switch (e) {
                error.PathAlreadyExists => {
                    out.info("  skipping combined output '{s}' (exists)\n", .{combined_out_name});
                    // combined_fout still points at combined_discarding.
                    combined_skipped = true;
                },
                else => return e,
            }
        } else {
            combined_out_file = try dir.createFile(combined_out_name, .{});
            combined_file_opened = true;
            combined_out_fw = combined_out_file.writer(&combined_out_file_buf);
            combined_fout = &combined_out_fw.interface;
        }

        // Emit header once for the entire combined output (unless --fresh
        // discarded into /dev/null).
        if (!combined_skipped) {
            const delim_out_local = &[_]u8{bc.csv_delimiter_out};
            if (bc.file_type_out == .json) {
                try combined_fout.writeAll("[\n");
            } else {
                for (bc.output_schema.items, 0..) |col, ci| {
                    if (ci > 0) try combined_fout.writeAll(delim_out_local);
                    try combined_fout.writeAll(col.header);
                }
                try combined_fout.writeAll("\n");
            }
        }
    }

    for (names.items) |filename| {
        // Per-file arena: owns file content, parsed lines, prepare context, output filename.
        // Freed automatically at the end of each file iteration.
        var file_arena = std.heap.ArenaAllocator.init(alloc);
        defer file_arena.deinit();
        const file_alloc = file_arena.allocator();

        // Counts input_schema expression failures across all rows of THIS file.
        // Bumps `stats.warnings` once when > 0 at file end so a config typo
        // that empties every $ticker (or any other variable) flips the
        // exit code to 2 and surfaces in the summary, instead of silently
        // producing useless output with exit 0.
        var file_expr_errors: u32 = 0;
        // Per-file non-fatal warnings (date-filter no-range, malformed range,
        // …) so `file_end.stats.warnings` reports a meaningful per-file
        // number instead of duplicating `file_expr_errors`. Aggregated into
        // `stats.warnings` at file end alongside section-level bumps.
        var file_warnings: u32 = 0;

        // Extract date range from filename when date_filter_from_filename is enabled.
        // Strip file_pattern_in from the filename to get the stem for date extraction.
        // Empty strings = no filtering.
        const stem = if (filename.len > bc.file_pattern_in.len)
            filename[0 .. filename.len - bc.file_pattern_in.len]
        else
            filename;
        const dr: DateRangeResult = if (bc.date_filter_from_filename)
            extractDateRange(stem)
        else
            .none;
        const date_min: []const u8 = switch (dr) {
            .valid => |r| r.min,
            else => "",
        };
        const date_max: []const u8 = switch (dr) {
            .valid => |r| r.max,
            else => "",
        };
        switch (dr) {
            .valid => |r| out.info("processing '{s}' with date range from {s} to {s}\n", .{ filename, r.min, r.max }),
            .invalid => {
                // A range was found but min > max (or a bad month/day made
                // it unparseable). Silent filtering here would drop every
                // row — warn and process unfiltered so the user notices.
                out.warning("warning: '{s}' has a malformed YYYY-MM-DD_YYYY-MM-DD range (min > max or bad component); processing all rows\n", .{filename});
                stats.warnings += 1;
                file_warnings += 1;
                out.info("processing '{s}'\n", .{filename});
            },
            .none => {
                // `date_filter_from_filename: true` but no range present in
                // the filename — every row processes unfiltered. This is
                // documented behaviour (test fixtures rely on it), but
                // production users almost always meant for filtering to
                // happen, so surface a warning when the gap appears.
                if (bc.date_filter_from_filename) {
                    out.warning("warning: '{s}' has no YYYY-MM-DD_YYYY-MM-DD range in filename; date_filter_from_filename is enabled but no rows will be filtered\n", .{filename});
                    stats.warnings += 1;
                    file_warnings += 1;
                }
                out.info("processing '{s}'\n", .{filename});
            },
        }

        // Open input file. CSV streams in 10 MiB chunks (chunk_arena
        // resets per chunk so peak memory is bounded by chunk size, not
        // file size). JSON still does a single whole-file load — JSON
        // exports are small in the bxp use cases and there's no
        // streaming JSON parser yet.
        var in_file = try dir.openFile(filename, .{});
        defer in_file.close();

        // Per-chunk arena shared by pre_pass and main passes; reset on
        // each chunk transition inside RowIterator.next().
        var chunk_arena = std.heap.ArenaAllocator.init(alloc);
        defer chunk_arena.deinit();

        // Header structures persist across all chunks (live in file_alloc).
        var col_index = std.StringHashMap(usize).init(file_alloc);
        var col_names = std.array_list.Managed([]const u8).init(file_alloc);

        // Pre_pass results — populated in the streaming pre_pass below
        // (CSV) or the in-memory pre_pass over all_rows (JSON). Empty
        // when no pre_pass blocks are configured. Lives in file_alloc
        // so it survives both passes.
        var lookup_table = std.StringHashMap([]const u8).init(file_alloc);

        // JSON path materialises rows up front; CSV streams them per chunk.
        var json_all_rows: ?std.array_list.Managed([][]const u8) = null;

        // Lazily-initialised main-pass iterator for CSV. Declared here
        // so checkUnknownFields / file_start / output sink setup can run
        // between parseHeader and the row loop, while the iter+reader
        // live for the entire iteration.
        var main_reader: ChunkReader = undefined;
        var main_reader_inited = false;
        defer if (main_reader_inited) main_reader.deinit();
        var main_iter: RowIterator = undefined;

        if (bc.file_type_in == .json) {
            // JSON: whole-file read, then build col_names/index + materialise rows.
            const content_raw = try in_file.readToEndAlloc(file_alloc, MAX_FILE_SIZE_BYTES);
            const content = if (std.mem.startsWith(u8, content_raw, "\xEF\xBB\xBF"))
                content_raw[3..]
            else
                content_raw;
            if (!std.unicode.utf8ValidateSlice(content)) {
                stats.warnings += 1;
                out.warning("warning: '{s}' is not valid UTF-8; non-ASCII characters may be garbled\n", .{filename});
            }
            var rows = std.array_list.Managed([][]const u8).init(file_alloc);
            try json_mod.readJsonRecords(file_alloc, content, &col_names, &rows);
            for (col_names.items, 0..) |name, idx| try col_index.put(name, idx);
            json_all_rows = rows;

            // JSON pre_pass iterates the materialised rows directly.
            if (bc.pre_passes.count() > 0) {
                for (rows.items) |fields| {
                    try evalPrepassRow(fields, &col_index, &lookup_table, bc, file_alloc, out);
                }
            }
        } else if (bc.pre_passes.count() > 0) {
            // CSV with pre_pass: two-pass — header+pre_pass first, then
            // seek back and create a fresh main-pass iterator.
            var pp_reader = try ChunkReader.init(file_alloc, in_file, bc.csv_text_quote_in);
            defer pp_reader.deinit();
            var pp_iter = try RowIterator.init(&pp_reader, &chunk_arena, file_alloc, bc.csv_delimiter_in, bc.csv_text_quote_in);

            const raw_header = try pp_iter.parseHeader();
            const truncated = raw_header.len > MAX_COLUMNS;
            const header_fields = if (truncated) raw_header[0..MAX_COLUMNS] else raw_header;
            if (truncated) {
                stats.warnings += 1;
                out.warning("warning: '{s}' has more than {d} columns; extra columns are ignored\n", .{ filename, MAX_COLUMNS });
            }
            for (header_fields, 0..) |name, idx| {
                // Intentional RFC 4180 deviation: trim spaces from column header
                // names so that [ColumnName] references work regardless of padding.
                const trimmed = std.mem.trim(u8, name, " ");
                const owned = try file_alloc.dupe(u8, trimmed);
                try col_index.put(owned, idx);
                try col_names.append(owned);
            }
            // First-chunk UTF-8 validation. Chunk boundaries always
            // land on '\n' (ASCII), so a multi-byte sequence is never
            // split across chunks; each chunk is independently
            // validatable. We validate only the first chunk to
            // approximate the legacy single-shot whole-file check
            // (cheap proxy for the common "BOM + Windows-1250 export"
            // failure mode).
            if (pp_reader.buffer.items.len > 0 and
                !std.unicode.utf8ValidateSlice(pp_reader.buffer.items[0..pp_reader.last_emit_len]))
            {
                stats.warnings += 1;
                out.warning("warning: '{s}' is not valid UTF-8; non-ASCII characters may be garbled\n", .{filename});
            }

            while (try pp_iter.next()) |fields| {
                try evalPrepassRow(fields, &col_index, &lookup_table, bc, file_alloc, out);
            }

            try in_file.seekTo(0);
            main_reader = try ChunkReader.init(file_alloc, in_file, bc.csv_text_quote_in);
            main_reader_inited = true;
            main_iter = try RowIterator.init(&main_reader, &chunk_arena, file_alloc, bc.csv_delimiter_in, bc.csv_text_quote_in);
            _ = try main_iter.parseHeader(); // discard, col_names already populated
        } else {
            // CSV without pre_pass: parse header straight from the
            // main-pass iterator (no rewind needed).
            main_reader = try ChunkReader.init(file_alloc, in_file, bc.csv_text_quote_in);
            main_reader_inited = true;
            main_iter = try RowIterator.init(&main_reader, &chunk_arena, file_alloc, bc.csv_delimiter_in, bc.csv_text_quote_in);

            const raw_header = try main_iter.parseHeader();
            const truncated = raw_header.len > MAX_COLUMNS;
            const header_fields = if (truncated) raw_header[0..MAX_COLUMNS] else raw_header;
            if (truncated) {
                stats.warnings += 1;
                out.warning("warning: '{s}' has more than {d} columns; extra columns are ignored\n", .{ filename, MAX_COLUMNS });
            }
            for (header_fields, 0..) |name, idx| {
                const trimmed = std.mem.trim(u8, name, " ");
                const owned = try file_alloc.dupe(u8, trimmed);
                try col_index.put(owned, idx);
                try col_names.append(owned);
            }
            if (main_reader.buffer.items.len > 0 and
                !std.unicode.utf8ValidateSlice(main_reader.buffer.items[0..main_reader.last_emit_len]))
            {
                stats.warnings += 1;
                out.warning("warning: '{s}' is not valid UTF-8; non-ASCII characters may be garbled\n", .{filename});
            }
        }

        // Phase G2: cross-reference [FieldName] expressions against the
        // actual CSV / JSON header. `expr.fieldByName` silently returns
        // "" for unknown names — typo `[Quantitty]` produces an empty
        // output column with no diagnostic. Warning at first close
        // mismatch (Levenshtein ≤ 2 to a real header). High-distance
        // mismatches are silent — legitimate optional / cross-version
        // columns. Warning bumps `stats.warnings` so exit code flips
        // to 2 but the file still processes (silent fallback "" is
        // preserved at runtime, matching the legacy behaviour).
        if (try checkUnknownFields(bc, &col_index, file_alloc, out, filename)) {
            stats.warnings += 1;
        }

        // No-rows warning. JSON knows the count up front and warns now;
        // for CSV the count is unknown until the streaming main loop
        // finishes, so the warning is deferred to file_end below.
        if (json_all_rows) |jr| if (jr.items.len == 0) {
            stats.warnings += 1;
            out.warning("warning: no rows in '{s}' (template: {s}, file: {s}/{s})\n", .{ filename, bid, dir_path, filename });
        };

        const full_path = try std.fs.path.join(file_alloc, &.{ dir_path, filename });
        var out_header_names = std.array_list.Managed([]const u8).init(file_alloc);
        for (bc.output_schema.items) |col| {
            try out_header_names.append(col.header);
        }
        // file_start.rows: known for JSON, 0 for CSV streaming (the
        // accurate count is reported in file_end below).
        out.event("file_start", .{
            .template = bid,
            .path = full_path,
            .rows = if (json_all_rows) |jr| jr.items.len else 0,
            .headers = col_names.items,
            .output_headers = out_header_names.items,
        });

        const has_prepass = bc.pre_passes.count() > 0;
        const lookup_table_ptr: ?*const std.StringHashMap([]const u8) =
            if (has_prepass) &lookup_table else null;
        // Implicit name for 2-arg LOOKUP — only defined when exactly one block exists.
        // ArrayHashMap exposes `.keys()` directly (slice of all keys in
        // insertion order); use index 0 since count == 1.
        const single_prepass_name: ?[]const u8 = blk: {
            if (bc.pre_passes.count() != 1) break :blk null;
            break :blk bc.pre_passes.keys()[0];
        };

        // Derive output filename.
        // Convention: strip file_pattern_in suffix and append file_pattern_out.
        // Example: "export_3.csv" with file_pattern_in="_3.csv" and
        // file_pattern_out="_3.csvx" → "export_3.csvx".
        // When file_pattern_out is not set, the fallback appends a literal "x"
        // to the full input filename: "export.csv" → "export.csvx". This keeps
        // the output file distinguishable from the input in the same directory
        // without requiring every template to spell out the suffix explicitly.
        const out_name = if (bc.file_pattern_out.len > 0 and
            std.mem.endsWith(u8, filename, bc.file_pattern_in))
            try std.mem.concat(file_alloc, u8, &.{
                filename[0 .. filename.len - bc.file_pattern_in.len],
                bc.file_pattern_out,
            })
        else
            try std.mem.concat(file_alloc, u8, &.{ filename, "x" });
        // --fresh under dry-run: still meaningful for the user to see which
        // files would be skipped, so check via access() — no file is created.
        if (fresh and out.dry_run) {
            const exists = blk: {
                dir.access(out_name, .{}) catch |e| {
                    if (e == error.FileNotFound) break :blk false;
                    return e;
                };
                break :blk true;
            };
            if (exists) {
                out.info("  skipping '{s}' (output exists)\n", .{filename});
                continue;
            }
        }

        // Output sink: real file, or Discarding writer under --dry-run.
        //
        // Under --fresh, the real-write path uses an atomic O_EXCL create
        // so another process racing the access()→createFile() window
        // can't make us silently overwrite their output.
        //
        // The Discarding writer under --dry-run still goes through the full
        // pipeline (expression evaluation, row rules, output formatting),
        // so timing and row counts in the trace events are representative
        // of a real run. The write buffer is reused as scratch space for
        // the Discarding sink — it's never flushed to disk.
        var out_file: std.fs.File = undefined;
        var out_file_buf: [OUT_FILE_BUF_SIZE]u8 = undefined;
        var out_fw: std.fs.File.Writer = undefined;
        var discarding: std.Io.Writer.Discarding = undefined;
        var per_file_opened = false;
        const fout: *std.Io.Writer = blk_sink: {
            if (out.dry_run) {
                discarding = .init(&out_file_buf);
                break :blk_sink &discarding.writer;
            }
            if (fresh) {
                if (dir.createFile(out_name, .{ .exclusive = true })) |f| {
                    out_file = f;
                } else |e| switch (e) {
                    error.PathAlreadyExists => {
                        // Per-file output already exists. If the combined
                        // sink still needs rows (combined enabled and not
                        // also skipped), keep iterating with a Discarding
                        // per-file writer so the combined gets filled —
                        // mirroring the "full run without --fresh" target
                        // state. Otherwise skip the whole iteration.
                        if (combined and !combined_skipped) {
                            out.info("  skipping per-file '{s}' (exists; combined still being built)\n", .{filename});
                            discarding = .init(&out_file_buf);
                            break :blk_sink &discarding.writer;
                        }
                        out.info("  skipping '{s}' (output exists)\n", .{filename});
                        continue;
                    },
                    else => return e,
                }
            } else {
                out_file = try dir.createFile(out_name, .{});
            }
            per_file_opened = true;
            out_fw = out_file.writer(&out_file_buf);
            break :blk_sink &out_fw.interface;
        };
        defer if (per_file_opened) out_file.close();
        const delim_out = &[_]u8{bc.csv_delimiter_out};
        // Per-file header — always emitted at the start of the per-file
        // sink. Combined-mode header was written once above the loop.
        if (bc.file_type_out == .json) {
            try fout.writeAll("[\n");
        } else {
            for (bc.output_schema.items, 0..) |col, ci| {
                if (ci > 0) try fout.writeAll(delim_out);
                try fout.writeAll(col.header);
            }
            try fout.writeAll("\n");
        }

        // Per-row arena: reset each iteration to reclaim expr evaluation allocations.
        // Expression evaluation (concat, error_detail, LOOKUP key construction,
        // DATE_CONVERT intermediates) allocates small strings that are only valid
        // for one row and should not accumulate across the file. Resetting the
        // arena with `.retain_capacity` keeps the already-mapped pages around so
        // subsequent rows don't pay for mmap overhead on every allocation.
        var line_arena = std.heap.ArenaAllocator.init(alloc);
        defer line_arena.deinit();
        const line_alloc = line_arena.allocator();

        var json_first_row = true;
        var file_rows_written: usize = 0;
        // Unified row source: JSON path replays the in-memory all_rows;
        // CSV path drives main_iter, which resets chunk_arena per chunk.
        var row_src: RowSource = if (json_all_rows) |jr|
            .{ .json_materialised = .{ .rows = jr.items, .idx = 0 } }
        else
            .{ .csv_streaming = &main_iter };
        var file_row_idx: usize = 0;
        while (try row_src.next()) |fields| : (file_row_idx += 1) {
            _ = line_arena.reset(.retain_capacity);
            out.event("row_start", .{ .file_row = file_row_idx + 1, .fields = fields });

            var row_detail: []const u8 = "";
            var row_ctx = expr_mod.Context{
                .fields = fields,
                .col_index = &col_index,
                .quote_out = bc.csv_text_quote_out,
                .ticker_map = &bc.ticker_map,
                .lookup_table = lookup_table_ptr,
                .single_prepass_name = single_prepass_name,
                .alloc = line_alloc,
                .decimal_sep_in = bc.csv_decimal_separator_in,
                .error_detail = &row_detail,
            };

            // Evaluate all input_schema variables for this row.
            var vars = try evalAllVars(bc.input_schema, &row_ctx, out, &file_expr_errors);

            // Row rules: first matching rule determines what to emit.
            // Rules are evaluated in declaration order; the loop breaks as
            // soon as one `when` condition is true. An error in a `when`
            // expression (e.g. type mismatch) is treated as "false" in
            // production mode (silent `""` substitution), but logged in
            // --debug mode so the user can see which expression failed.
            const rules = bc.row_rules orelse &.{};
            var rule_matched = false;
            var matched_rule_index: usize = 0;
            for (rules, 0..) |rule, rule_index| {
                row_detail = "";
                const when_val = expr_mod.eval(rule.when, &row_ctx) catch |err| {
                    if (out.debug) {
                        if (row_detail.len > 0) {
                            out.writer.print("[row_rules when error] \"{s}\": {s} ({s})\n", .{ rule.when, @errorName(err), row_detail }) catch {};
                        } else {
                            out.writer.print("[row_rules when error] \"{s}\": {s}\n", .{ rule.when, @errorName(err) }) catch {};
                        }
                        out.writer.flush() catch {};
                    }
                    out.event("rule_no_match", .{ .rule_index = rule_index, .when = rule.when, .@"error" = @errorName(err) });
                    continue;
                };
                if (!when_val.toBool()) {
                    out.event("rule_no_match", .{ .rule_index = rule_index, .when = rule.when });
                    continue;
                }
                rule_matched = true;
                matched_rule_index = rule_index;
                // Emit rule_match as a hand-built JSON object rather than
                // via Output.event() because the `rows` field is a nested
                // array-of-objects whose schema isn't known at compile time
                // (StringArrayHashMap values). The generic `event()` helper
                // uses `inline for` over a comptime-known struct, which
                // cannot represent runtime-keyed maps. On any write error
                // the labeled break abandons the partial object — the output
                // stream may then be in an inconsistent state, but write
                // errors on stdout are unrecoverable anyway.
                if (out.traceOn()) emit_rule_match: {
                    var jw: std.json.Stringify = .{ .writer = out.writer, .options = .{} };
                    jw.beginObject() catch break :emit_rule_match;
                    jw.objectField("t") catch break :emit_rule_match;
                    jw.write("rule_match") catch break :emit_rule_match;
                    jw.objectField("rule_index") catch break :emit_rule_match;
                    jw.write(rule_index) catch break :emit_rule_match;
                    jw.objectField("when") catch break :emit_rule_match;
                    jw.write(rule.when) catch break :emit_rule_match;
                    jw.objectField("rows") catch break :emit_rule_match;
                    jw.beginArray() catch break :emit_rule_match;
                    for (rule.rows) |row_override| {
                        jw.beginObject() catch break :emit_rule_match;
                        var it = row_override.iterator();
                        while (it.next()) |entry| {
                            jw.objectField(entry.key_ptr.*) catch break :emit_rule_match;
                            jw.write(entry.value_ptr.*) catch break :emit_rule_match;
                        }
                        jw.endObject() catch break :emit_rule_match;
                    }
                    jw.endArray() catch break :emit_rule_match;
                    jw.endObject() catch break :emit_rule_match;
                    out.writer.writeByte('\n') catch break :emit_rule_match;
                    out.writer.flush() catch break :emit_rule_match;
                }
                // Empty rows slice = silent skip.
                for (rule.rows, 0..) |row_override, output_row_index| {
                    // Start from base vars, then apply per-row overrides.
                    var merged = std.StringHashMap([]const u8).init(line_alloc);
                    var base_it = vars.iterator();
                    while (base_it.next()) |e| try merged.put(e.key_ptr.*, e.value_ptr.*);
                    var ov_it = row_override.iterator();
                    while (ov_it.next()) |e| {
                        row_detail = "";
                        const val = expr_mod.evalString(e.value_ptr.*, &row_ctx) catch |err| blk: {
                            if (out.debug) {
                                if (row_detail.len > 0) {
                                    out.writer.print("[row_rules error] {s} = \"{s}\": {s} ({s})\n", .{ e.key_ptr.*, e.value_ptr.*, @errorName(err), row_detail }) catch {};
                                } else {
                                    out.writer.print("[row_rules error] {s} = \"{s}\": {s}\n", .{ e.key_ptr.*, e.value_ptr.*, @errorName(err) }) catch {};
                                }
                                out.writer.flush() catch {};
                            }
                            out.event("var_error", .{ .name = e.key_ptr.*, .expr = e.value_ptr.*, .@"error" = @errorName(err), .detail = row_detail, .origin = "row_rules", .rule_index = rule_index, .output_row_index = output_row_index });
                            break :blk "";
                        };
                        out.event("var_eval", .{ .name = e.key_ptr.*, .expr = e.value_ptr.*, .value = val, .origin = "row_rules", .rule_index = rule_index, .output_row_index = output_row_index });
                        try merged.put(e.key_ptr.*, val);
                    }
                    // Date range filter (date_filter_from_filename).
                    // Compares only the first 10 bytes of $date so that
                    // ISO-8601 datetime strings ("2026-03-15T14:00:00Z")
                    // work alongside plain date strings ("2026-03-15") — the
                    // lexical prefix comparison is correct for both because
                    // ISO-8601 sorts chronologically as plain ASCII. When
                    // $date is shorter than 10 bytes (e.g. empty string due
                    // to an expression error), the guard `date_str.len >= 10`
                    // skips filtering and the row is passed through unfiltered
                    // rather than silently dropped.
                    const date_str = merged.get(VAR_DATE) orelse "";
                    if (date_min.len > 0 and date_str.len >= 10 and
                        std.mem.order(u8, date_str[0..10], date_min) == .lt) {
                        out.event("row_filtered", .{ .reason = "date_filter_from_filename" });
                        continue;
                    }
                    if (date_max.len > 0 and date_str.len >= 10 and
                        std.mem.order(u8, date_str[0..10], date_max) == .gt) {
                        out.event("row_filtered", .{ .reason = "date_filter_from_filename" });
                        continue;
                    }
                    // Collect output values for trace emission.
                    var out_values = std.array_list.Managed([]const u8).init(line_alloc);
                    for (bc.output_schema.items) |col| {
                        try out_values.append(merged.get(col.variable) orelse "");
                    }
                    if (bc.file_type_out == .json) {
                        if (!json_first_row) try fout.writeAll(",\n");
                        json_first_row = false;
                        try writeJsonRow(fout, bc.output_schema.items, &merged);
                        if (combined) {
                            // Same row to the additional combined sink.
                            // Its own first-row flag spans every input
                            // file so commas land between every pair
                            // regardless of file boundaries.
                            if (!combined_json_first_row) try combined_fout.writeAll(",\n");
                            combined_json_first_row = false;
                            try writeJsonRow(combined_fout, bc.output_schema.items, &merged);
                        }
                    } else {
                        var val_buf: [VAL_BUF_SIZE]u8 = undefined;
                        for (bc.output_schema.items, 0..) |col, ci| {
                            if (ci > 0) try fout.writeAll(delim_out);
                            try writeSafeValue(fout, merged.get(col.variable) orelse "", bc.csv_delimiter_out, bc.csv_decimal_separator_out, bc.csv_text_quote_out, &val_buf);
                        }
                        try fout.writeAll("\n");
                        if (combined) {
                            var val_buf2: [VAL_BUF_SIZE]u8 = undefined;
                            for (bc.output_schema.items, 0..) |col, ci| {
                                if (ci > 0) try combined_fout.writeAll(delim_out);
                                try writeSafeValue(combined_fout, merged.get(col.variable) orelse "", bc.csv_delimiter_out, bc.csv_decimal_separator_out, bc.csv_text_quote_out, &val_buf2);
                            }
                            try combined_fout.writeAll("\n");
                        }
                    }
                    out.event("row_output", .{ .values = out_values.items });
                    file_rows_written += 1;
                }
                break; // first matching rule wins
            }
            // Emit rule_no_match for rules that were never evaluated (after the match).
            // When a rule matched at index N, rules [N+1 ..] were short-circuited and
            // never evaluated. The GUI expects a rule_no_match for every rule on every
            // row so it can render all rows in the rules table, including the skipped
            // ones. Emitting them here (after the match loop) avoids changing the
            // loop's short-circuit semantics.
            if (rule_matched) {
                for (rules[matched_rule_index + 1 ..], matched_rule_index + 1 ..) |rule, ri| {
                    out.event("rule_no_match", .{ .rule_index = ri, .when = rule.when });
                }
            }
            if (!rule_matched) {
                // No rule matched — show as debug record if configured.
                if (bc.row_rules_debug_missing and out.debug) {
                    out.writer.print("[{s}] unmatched row (no row_rules entry):\n{{\n", .{bid}) catch {};
                    for (col_names.items, 0..) |col_name, ci| {
                        const val = if (ci < fields.len) fields[ci] else "";
                        const sep: []const u8 = if (ci + 1 < col_names.items.len) "," else "";
                        out.writer.print("  \"{s}\": \"{s}\"{s}\n", .{ col_name, val, sep }) catch {};
                    }
                    out.writer.print("}}\n", .{}) catch {};
                    out.writer.flush() catch {};
                }
            }
            out.event("row_end", .{});
        }

        // Per-file tail + flush — always emitted at end-of-iteration.
        // Combined sink's tail/flush is deferred until after the loop
        // so every input file contributes to one closing array bracket.
        if (bc.file_type_out == .json) try fout.writeAll("\n]\n");
        try fout.flush();

        // CSV no-rows warning: deferred from above because streaming
        // doesn't expose the count until the loop finishes.
        if (json_all_rows == null and file_row_idx == 0) {
            stats.warnings += 1;
            out.warning("warning: no rows in '{s}' (template: {s}, file: {s}/{s})\n", .{ filename, bid, dir_path, filename });
        }

        // Surface silent expression errors. Bump stats.warnings ONCE per
        // file (not per error) so a clean run is exit 0 but any file with
        // expression failures flips to exit 2 and gets an actionable line
        // (the GUI also picks up the warning text via the stderr pane).
        if (file_expr_errors > 0) {
            out.warning("warning: {d} input_schema expression error(s) in '{s}' (run with --debug to see details)\n", .{ file_expr_errors, filename });
            stats.warnings += 1;
        }

        out.event("file_end", .{
            .template = bid,
            .path = full_path,
            .stats = .{
                .rows = file_row_idx,
                .written = file_rows_written,
                // Per-file expression evaluation failures (input_schema
                // vars). Previously hardcoded 0; now populated from the
                // same counter that drives the file-end warning text. The
                // GUI's per-file " · N err" badge becomes meaningful.
                .errors = file_expr_errors,
                // Non-fatal per-file warnings (date filter no-range,
                // malformed filename range, …). Previously this field
                // duplicated `file_expr_errors`; now it carries the
                // distinct per-file warning count.
                .warnings = file_warnings,
            },
        });
    }

    // Combined mode: close the JSON array (if applicable) and flush the
    // single shared sink. The file handle itself is closed by the defer
    // attached to `combined_file_opened` above. Skipped when --fresh
    // already discarded into a no-op sink (file existed).
    if (combined and combined_file_opened) {
        if (bc.file_type_out == .json) try combined_fout.writeAll("\n]\n");
        try combined_fout.flush();
    }

    stats.time_ns = timer.read();
    return stats;
}

/// Converts xlsx files to intermediate CSV before the main processing loop.
///
/// Groups SheetSpecs by data_dir so each xlsx file is extracted only once,
/// even when multiple templates share the same directory.
/// Prints its own section header and summary when any xlsx files were found.
/// Returns accumulated SectionStats for this pre-pass.
pub fn xlsxPrePass(
    cfg: *const config_mod.Config,
    alloc: std.mem.Allocator,
    out: Output,
    fresh: bool,
    template_id: ?[]const u8,
    dir_path_arg: ?[]const u8,
) !SectionStats {
    var xlsx_stats = SectionStats{};
    var timer = try std.time.Timer.start();

    var dir_specs = std.StringArrayHashMap(std.array_list.Managed(xlsx_mod.SheetSpec)).init(alloc);
    defer {
        var ds_it = dir_specs.iterator();
        while (ds_it.next()) |e| e.value_ptr.deinit();
        dir_specs.deinit();
    }

    // Collect SheetSpecs per data_dir across all active templates.
    var bc_it = cfg.brokers.iterator();
    while (bc_it.next()) |entry| {
        const bc = entry.value_ptr;
        const sheet = bc.xlsx_sheet orelse continue;

        // Resolve effective data_dir: the dir_path_arg override applies only
        // to the selected template when --template is used.
        const dir_path: []const u8 = if (template_id) |tid| blk: {
            if (!std.mem.eql(u8, tid, entry.key_ptr.*)) continue;
            break :blk dir_path_arg orelse bc.data_dir;
        } else bc.data_dir;

        const gop = try dir_specs.getOrPut(dir_path);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.array_list.Managed(xlsx_mod.SheetSpec).init(alloc);
        }
        try gop.value_ptr.append(.{
            .name = sheet.name,
            .header_row = sheet.header_row,
            .output_suffix = sheet.output_suffix,
        });
    }

    if (dir_specs.count() == 0) return xlsx_stats;

    out.info("\n=== preparing work environment ===\n", .{});

    var ds_it = dir_specs.iterator();
    while (ds_it.next()) |e| {
        const dir_path = e.key_ptr.*;
        const specs = e.value_ptr.items;

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                out.fatal("error: directory not found: '{s}'\n", .{dir_path});
                xlsx_stats.has_fatal = true;
                continue;
            }
            return err;
        };
        defer dir.close();

        var xlsx_names = std.array_list.Managed([]u8).init(alloc);
        defer {
            for (xlsx_names.items) |n| alloc.free(n);
            xlsx_names.deinit();
        }
        {
            var fit = dir.iterate();
            while (try fit.next()) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (!std.mem.endsWith(u8, entry.name, ".xlsx")) continue;
                try xlsx_names.append(try alloc.dupe(u8, entry.name));
            }
        }
        std.mem.sort([]u8, xlsx_names.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (xlsx_names.items) |xlsx_name| {
            const stem = xlsx_name[0 .. xlsx_name.len - 5];

            // --fresh: skip xlsx conversion if ALL expected intermediate CSV
            // outputs already exist. The check uses an AND condition rather
            // than OR: if even one output is missing the xlsx file is
            // re-extracted in full. This is intentional — partial extraction
            // (e.g. only _closed.csv present, _cash.csv missing) would leave
            // the template with stale data for the missing sheet. The cost
            // of a full re-extraction on a partial miss is negligible
            // compared to processing an entire file directory.
            if (fresh) {
                var all_exist = true;
                for (specs) |spec| {
                    const csvx_name = try std.mem.concat(alloc, u8, &.{ stem, spec.output_suffix, "x" });
                    defer alloc.free(csvx_name);
                    dir.access(csvx_name, .{}) catch {
                        all_exist = false;
                        break;
                    };
                }
                if (all_exist) {
                    out.info("  skipping '{s}' (output exists)\n", .{xlsx_name});
                    continue;
                }
            }

            const xlsx_file = try dir.openFile(xlsx_name, .{});
            defer xlsx_file.close();

            out.info("converting '{s}'\n", .{xlsx_name});
            xlsx_mod.xlsxToCsv(alloc, xlsx_file, specs, dir, stem) catch |err| {
                out.fatal("fatal error: xlsx conversion failed for '{s}': {s}\n", .{ xlsx_name, @errorName(err) });
                xlsx_stats.has_fatal = true;
                xlsx_stats.time_ns = timer.read();
                out.summary(xlsx_stats);
                return error.Fatal;
            };
        }
    }

    xlsx_stats.time_ns = timer.read();
    out.summary(xlsx_stats);
    return xlsx_stats;
}
