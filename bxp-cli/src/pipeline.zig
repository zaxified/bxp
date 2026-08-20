/// Processing pipeline for bxp-cli: per-template file conversion and xlsx pre-pass.
///
/// Owns the core data-processing logic: reading input files, evaluating expressions,
/// applying row rules, and writing output.  CLI argument parsing and config loading
/// live in main.zig; all types that main.zig needs are exported as pub.

const std = @import("std");
/// CSV record model + streaming chunk reader (the zig-libs `csvstream` module,
/// re-exported by bxp-core). Both halves used to live here: the record
/// iterator as `bxp-core/src/csv.zig`, the `ChunkReader` privately in this
/// file. `csv` stays the local alias so the call sites read unchanged.
const csv = @import("csvstream");
const config_mod = @import("config");
const expr_mod = @import("expr");
/// Layer 0 transcoder, re-exported by the config module. Used for output
/// encoding (UTF-8 → target code page); input decoding happens inside
/// `expr.Context.field` driven by `Context.input_encoding`.
const encoding = config_mod.encoding;
const xlsx_mod = @import("xlsx");
const zipstream = @import("zipstream");
const json_mod = @import("json");
const btrace = @import("btrace");

// Broker exports typically have 10–30 columns; real-world public datasets
// can reach 100+ (NOAA GHCN daily has 124) and wide time-series go much
// further (Johns Hopkins COVID-19 daily series = 1147 day-columns). The
// per-worker field buffer is heap-allocated (`field_buf`, one
// `[]const u8` slot per column), so the ceiling costs only
// `@sizeOf([]const u8) * MAX_COLUMNS` (16 B/slot × 16384 = 256 KiB) per
// worker — measured peak RSS for a 5000-col × 100k-row input was ~13 MB.
// 16384 is therefore a
// generous ceiling at negligible cost; header/rows beyond it are truncated
// with a warning. The GUI renders far fewer (see `kMaxDisplayCols`) — it is
// a debug view, not a wide-CSV viewer — so the CLI cap is the real limit.
const MAX_COLUMNS: usize = 16384;
// One 64 KB write buffer per output file. Kept in the per-file stack frame;
// the OS then decides when to flush to disk. Smaller buffers cause noticeable
// syscall overhead on files with thousands of short rows.
const OUT_FILE_BUF_SIZE: usize = 65536;
// Stack buffer for decimal-separator substitution in writeSafeValue.
// Real numeric outputs are short ("123456789.12345678" = 18 chars); anything
// longer is treated as non-numeric and passed through verbatim.
const VAL_BUF_SIZE: usize = 64;
// JSON parallel pipeline block size: records buffered by the serial
// Scanner-based RecordReader before fork-joining the worker pool. 1024
// amortises dispatch overhead across enough rows that workers do real
// work per spawn, while keeping the block arena footprint bounded
// (records' field bytes accumulate until the block drains).
const JSON_PARALLEL_BLOCK_SIZE: usize = 1024;
/// Runtime key for the date variable in the merged vars map (the `$date`
/// entry declared in input_schema).
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
    /// Counters fed to the `--debug=json` machine-readable run summary. The
    /// human stdout summary ignores them (it only prints errors/warnings/time),
    /// so they cost nothing on the normal path. `files` = input files actually
    /// processed (skipped-existing files do not count); `rows_in` = source
    /// records read; `rows_out` = output rows written (may exceed `rows_in`
    /// when a `row_rules` rule expands one input row into several).
    files: u32 = 0,
    rows_in: u64 = 0,
    rows_out: u64 = 0,

    pub fn merge(self: *SectionStats, other: SectionStats) void {
        self.warnings += other.warnings;
        if (other.has_fatal) self.has_fatal = true;
        self.time_ns += other.time_ns;
        self.files += other.files;
        self.rows_in += other.rows_in;
        self.rows_out += other.rows_out;
    }
};

/// Trace mode for `--trace`. Two reachable values:
///   `.off` — no trace emission (default).
///   `.bin` — binary BXTB frame stream on stdout (and optional
///            `--trace-file` mirror). See `bxp-core/src/btrace.zig`
///            for the frame protocol.
///
/// The NDJSON `--trace` / `--trace=json` mode was removed in v0.3.0;
/// per-row drill-down detail is recomputed on demand by the GUI via the
/// bridge (`inspect.evalBatch`) from the BXTB metadata + the source CSV.
pub const TraceMode = enum(u2) { off, bin };

/// Execution resources shared across one CLI invocation. `max_workers` is the
/// per-block parallel-evaluation fan-out ceiling (= `std.Thread.getCpuCount()`
/// typically, clamped by `MAX_WORKERS_LIMIT`); the worker tasks run via
/// `std.Io.Group.async` over `io`'s own pool (Zig 0.16 retired the explicit
/// `std.Thread.Pool`/`WaitGroup`), so there is no separate pool object to own.
pub const Runtime = struct {
    max_workers: usize,
    /// Io instance for filesystem access + timing, threaded from `main`'s
    /// `std.process.Init`. The single carrier for `std.Io.Dir`/`File` ops and
    /// `std.Io.Clock` timing across the pipeline (Zig 0.16 — `std.fs`/`std.time`
    /// no longer offer io-free entry points).
    io: std.Io,
};

/// Monotonic wall-clock timer. Zig 0.16 removed `std.time.Timer` (and the
/// io-free `clock_gettime`); timing now goes through `Io`. This thin shim keeps
/// the `timer.read()` call sites in the section functions unchanged — only the
/// construction switches from `std.time.Timer.start()` to `Timer.begin(io)`.
/// `pub` so main.zig's `run()` shares the same shim.
pub const Timer = struct {
    io: std.Io,
    start: std.Io.Clock.Timestamp,

    pub fn begin(io: std.Io) Timer {
        return .{ .io = io, .start = std.Io.Clock.Timestamp.now(io, .awake) };
    }

    /// Nanoseconds elapsed since `begin`. Monotonic, so never negative; clamps
    /// to 0 defensively.
    pub fn read(self: Timer) u64 {
        const ns = self.start.untilNow(self.io).raw.nanoseconds;
        return if (ns > 0) @intCast(ns) else 0;
    }
};

/// Output wrapper that suppresses all writes when --quiet or --trace is active.
/// All methods silently drop write errors (same pattern as existing debug prints).
/// When --trace is active, human-readable lines are suppressed so that stdout
/// contains only the binary BXTB frame stream.
pub const Output = struct {
    writer: *Writer,
    quiet: bool,
    debug: bool,
    trace: TraceMode = .off,
    dry_run: bool = false,
    /// `--debug=json` mode. When true, all human-readable stdout (info /
    /// per-section summary / overall line) is suppressed and `warning` /
    /// `fatal` text is captured into `msg_sink` instead of going to stderr,
    /// so the run produces exactly one machine-readable JSON document on
    /// stdout (emitted by `run()` / `main()`). Mutually exclusive with
    /// `--trace` and `--quiet` (rejected up-front in main).
    json_debug: bool = false,
    /// Collector for captured `warning` / `fatal` lines in `json_debug` mode.
    /// Null in every other mode. Owned by main(); strings are allocated with
    /// `msg_alloc`.
    msg_sink: ?*std.array_list.Managed([]const u8) = null,
    /// Allocator backing the captured `msg_sink` strings. Only read when
    /// `msg_sink != null`.
    msg_alloc: std.mem.Allocator = undefined,
    /// Non-null iff `trace == .bin`. Owned by the caller (main.zig); we just
    /// route bin-mode emits through it.
    btrace_writer: ?*btrace.Writer = null,
    /// Non-null iff `--trace-file <path>` was given. Receives the same
    /// byte stream as `btrace_writer` (one writer per sink, identical
    /// content) so users can run with `--trace` going to a downstream
    /// process and also persist the stream to disk in parallel.
    btrace_file_writer: ?*btrace.Writer = null,

    /// True when any trace events are being emitted. Used to suppress
    /// human-readable summaries that would interleave with the binary
    /// frame stream on stdout.
    inline fn traceOn(self: Output) bool {
        return self.trace != .off;
    }

    /// Captures one formatted diagnostic line into `msg_sink` (json_debug
    /// mode). The trailing newline that the call sites include for stderr is
    /// trimmed so each array entry is a clean one-line message. Allocation
    /// failure silently drops the line — never abort a run over a diagnostic.
    fn captureMsg(self: Output, comptime fmt: []const u8, args: anytype) void {
        const sink = self.msg_sink orelse return;
        const s = std.fmt.allocPrint(self.msg_alloc, fmt, args) catch return;
        sink.append(std.mem.trimEnd(u8, s, "\n")) catch {};
    }

    /// Print an informational line. Suppressed in --quiet, --trace, or
    /// --debug=json mode (the last reserves stdout for the JSON document).
    pub fn info(self: Output, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet or self.traceOn() or self.json_debug) return;
        self.writer.print(fmt, args) catch {};
        self.writer.flush() catch {};
    }

    /// Print a warning line. Suppressed in --quiet mode. Goes to stderr in
    /// every mode: in --trace mode stdout is reserved for the binary BXTB
    /// frame stream (interleaving raw text would break the GUI's frame
    /// reader); in normal mode diagnostic output belongs on stderr per
    /// Unix convention so users redirecting stdout to a file don't get
    /// warnings inlined into their data.
    pub fn warning(self: Output, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet) return;
        if (self.json_debug) return self.captureMsg(fmt, args);
        std.debug.print(fmt, args);
    }

    /// Print a fatal-error line. Suppressed in --quiet mode. Goes to stderr
    /// for the same reasons as `warning` above — the GUI's BXTB frame reader
    /// must see only frames on stdout, and CLI users running e.g.
    /// `bxp-cli > out.csvx` need diagnostics out-of-band from the data.
    pub fn fatal(self: Output, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet) return;
        if (self.json_debug) return self.captureMsg(fmt, args);
        std.debug.print(fmt, args);
    }

    /// Print a per-section summary line. Suppressed in --quiet, --trace, or
    /// --debug=json mode.
    pub fn summary(self: Output, stats: SectionStats) void {
        if (self.quiet or self.traceOn() or self.json_debug) return;
        const errors: u32 = if (stats.has_fatal) 1 else 0;
        const secs = stats.time_ns / 1_000_000_000;
        const ms = (stats.time_ns % 1_000_000_000) / 1_000_000;
        self.writer.print("summary: errors:{d} warnings:{d} time:{d}.{d:0>3}s\n", .{ errors, stats.warnings, secs, ms }) catch {};
        self.writer.flush() catch {};
    }

    /// Print the overall summary line (no leading "summary:" label).
    /// Suppressed in --quiet, --trace, or --debug=json mode.
    pub fn overallLine(self: Output, stats: SectionStats) void {
        if (self.quiet or self.traceOn() or self.json_debug) return;
        const errors: u32 = if (stats.has_fatal) 1 else 0;
        const secs = stats.time_ns / 1_000_000_000;
        const ms = (stats.time_ns % 1_000_000_000) / 1_000_000;
        self.writer.print("errors:{d} warnings:{d} time:{d}.{d:0>3}s\n", .{ errors, stats.warnings, secs, ms }) catch {};
        self.writer.flush() catch {};
    }

    // ─────────────────────── Binary-trace emit methods ───────────────────────
    // Each method fans out to both writers when present. The two sinks
    // receive identical byte streams — `btrace_file_writer` is just a
    // disk mirror of the stdout stream so users can persist the trace
    // without piping it.

    pub fn binEmitFileStart(
        self: Output,
        input_format: btrace.InputFormat,
        template: []const u8,
        path: []const u8,
        headers: []const []const u8,
    ) void {
        if (self.btrace_writer) |bw| {
            bw.writeFileStart(input_format, template, path, headers) catch {};
        }
        if (self.btrace_file_writer) |bw| {
            bw.writeFileStart(input_format, template, path, headers) catch {};
        }
    }

    pub fn binEmitFileEnd(
        self: Output,
        source_rows: u64,
        written_rows: u64,
        errors: u32,
        warnings: u32,
    ) void {
        if (self.btrace_writer) |bw| {
            bw.writeFileEnd(source_rows, written_rows, errors, warnings) catch {};
        }
        if (self.btrace_file_writer) |bw| {
            bw.writeFileEnd(source_rows, written_rows, errors, warnings) catch {};
        }
    }

    pub fn binEmitOutputRow(
        self: Output,
        source_locator: u64,
        output_idx: u64,
        rule_idx: i32,
        action: []const u8,
    ) void {
        if (self.btrace_writer) |bw| {
            bw.writeOutputRow(source_locator, output_idx, rule_idx, action) catch {};
        }
        if (self.btrace_file_writer) |bw| {
            bw.writeOutputRow(source_locator, output_idx, rule_idx, action) catch {};
        }
    }

    pub fn binEmitFilteredRow(self: Output, source_locator: u64, reason: []const u8) void {
        if (self.btrace_writer) |bw| {
            bw.writeFilteredRow(source_locator, reason) catch {};
        }
        if (self.btrace_file_writer) |bw| {
            bw.writeFilteredRow(source_locator, reason) catch {};
        }
    }

    pub fn binEmitErrorRow(
        self: Output,
        source_locator: u64,
        var_name: []const u8,
        error_kind: []const u8,
        detail: []const u8,
        origin: []const u8,
    ) void {
        if (self.btrace_writer) |bw| {
            bw.writeErrorRow(source_locator, var_name, error_kind, detail, origin) catch {};
        }
        if (self.btrace_file_writer) |bw| {
            bw.writeErrorRow(source_locator, var_name, error_kind, detail, origin) catch {};
        }
    }

    pub fn binEmitPrepassEntry(
        self: Output,
        name: []const u8,
        key: []const u8,
        field: []const u8,
        value: []const u8,
    ) void {
        if (self.btrace_writer) |bw| {
            bw.writePrepassEntry(name, key, field, value) catch {};
        }
        if (self.btrace_file_writer) |bw| {
            bw.writePrepassEntry(name, key, field, value) catch {};
        }
    }

    pub fn binEmitDone(self: Output, exit_code: i32) void {
        if (self.btrace_writer) |bw| {
            bw.writeDone(exit_code) catch {};
            self.writer.flush() catch {};
        }
        if (self.btrace_file_writer) |bw| {
            bw.writeDone(exit_code) catch {};
        }
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

/// Transcode a UTF-8 output cell / header to the configured CSV output code
/// page. `.utf8` (the default) returns the input unchanged with no allocation;
/// any other encoding allocates the transcoded bytes from `alloc`. Applied at
/// the CSV write edge so the internal UTF-8 currency lands in the file as the
/// user's requested legacy encoding.
fn encodeOutCell(alloc: std.mem.Allocator, value: []const u8, enc: encoding.Encoding) ![]const u8 {
    if (enc == .utf8) return value;
    return encoding.encodeFromUtf8(alloc, value, enc);
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

/// True when a value carries the machinery a spreadsheet formula needs in order
/// to *do* something: a function call (`SUM(`) or a DDE link
/// (`cmd|'/c calc'!A1`). Bare text after a sign cannot execute — a cell reading
/// `-ISM FURNITURE` renders as `#NAME?` at worst.
fn hasFormulaMachinery(s: []const u8) bool {
    var seen_pipe = false;
    for (s, 0..) |ch, i| {
        switch (ch) {
            // `IDENT(` is a call. The identifier byte in front of the paren is
            // what separates `SUM(A1)` from prose like `Foo (Ltd)`.
            '(' => if (i > 0 and isIdentByte(s[i - 1])) return true,
            // DDE: `cmd|'/c calc'!A1`, `MSEXCEL|'\\..\\file'!A1`.
            '|' => seen_pipe = true,
            '!' => if (seen_pipe) return true,
            else => {},
        }
    }
    return false;
}

/// True when `value` reads as a spreadsheet formula rather than as data — i.e.
/// when writing it verbatim would let Excel / LibreOffice / Sheets evaluate the
/// cell instead of showing it.
///
/// A leading `=` (or a tab / CR hiding one) always counts: it opens a formula
/// everywhere, quoted or not. The corpus scan behind this rule — `datasets/`,
/// `docs/examples/` incl. the full-scale inputs, and the real broker exports —
/// found that shape three times in ~13 M rows (IMDb titles like `=x`), so
/// guarding it unconditionally costs almost nothing.
///
/// A leading `+`, `-` or `@` counts only in company with formula machinery.
/// Those bytes lead far more data than formulas: signed numbers,
/// `+420 555 0101`, `-$1,259.59`, business names (`-ISM FURNITURE, LLC`),
/// handles (`@midnight with …`). Prefixing those writes an apostrophe into a
/// value that is not a formula and cannot become one — the same over-prefixing
/// `30ee2ac` fixed for signed numbers, generalised so the machinery decides
/// rather than the first byte. It also closes the reverse hole: `-1+cmd|…!A1`
/// starts with a digit-led sign and used to slip through unguarded.
fn looksLikeFormula(value: []const u8) bool {
    if (value.len == 0) return false;
    return switch (value[0]) {
        '=', '\t', '\r' => true,
        '+', '-', '@' => hasFormulaMachinery(value[1..]),
        else => false,
    };
}

/// Writes value to out.
///
/// When quote_out != 0 and the value contains the output delimiter, the quote
/// character, \r, or \n, the value is wrapped in quote_out characters and any
/// internal occurrences of quote_out are doubled (RFC 4180 §2.5–2.7).
///
/// A value that `looksLikeFormula` gets a leading single-quote to neutralise
/// injection — on **every** path, quoted or not. A spreadsheet strips CSV
/// quoting before it parses the cell, so `"=1+2"` evaluates exactly like
/// `=1+2` (verified against LibreOffice 26.2); guarding only the unquoted path
/// made the guard depend on whether the value happened to contain a delimiter.
///
/// When no quoting is applied, embedded \n is additionally replaced with the
/// literal two-char sequence \n and \r bytes are dropped.
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
        const body = s[1 .. s.len - 1];
        try out.writeByte(quote_out);
        // The guard goes inside the quotes: they are stripped by the
        // spreadsheet before the cell is parsed, so an apostrophe outside them
        // would neutralise nothing.
        if (looksLikeFormula(body)) try out.writeByte('\'');
        for (body) |ch| {
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
            if (looksLikeFormula(s)) try out.writeByte('\'');
            for (s) |ch| {
                if (ch == quote_out) try out.writeByte(quote_out); // escape: double it
                try out.writeByte(ch);
            }
            try out.writeByte(quote_out);
            return;
        }
    }
    // No quoting applied: formula-injection prefix + \n→\n literal replacement.
    if (looksLikeFormula(s)) try out.writeByte('\'');
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
    schema: std.StringArrayHashMapUnmanaged([]const u8),
    ctx: *expr_mod.Context,
    out: Output,
    error_count: *u32,
    source_locator: u64,
    folded: ?*const std.StringHashMap([]const u8),
    skip: ?*const std.StringHashMap(void),
    compiled: ?[]const expr_mod.Node,
) !std.StringHashMap([]const u8) {
    var vars = std.StringHashMap([]const u8).init(ctx.alloc);
    var detail: []const u8 = "";
    const saved_detail = ctx.error_detail;
    ctx.error_detail = &detail;
    defer ctx.error_detail = saved_detail;
    // Index-based walk so `compiled[i]` (Phase 3B) aligns with the i-th schema
    // entry (StringArrayHashMap preserves declaration order).
    const keys = schema.keys();
    const values = schema.values();
    for (keys, values, 0..) |key, value, i| {
        // opt 2: the winning rule overwrites this var in every output row, so its
        // base value is dead work — skip it. The override supplies the value.
        if (skip) |sk| {
            if (sk.contains(key)) continue;
        }
        // Constant fold: row-invariant vars were evaluated once at file-start.
        // Reuse the precomputed value — byte-identical to per-row eval since
        // the expression references no field/lookup/nondeterministic builtin.
        if (folded) |fm| {
            if (fm.get(key)) |fv| {
                try vars.put(key, fv);
                continue;
            }
        }
        detail = "";
        // Phase 3B: evaluate the precompiled node when available (byte-identical
        // to evalString of the source); else evaluate the source directly.
        const eval_result = if (compiled) |nodes|
            expr_mod.evalNodeString(&nodes[i], ctx)
        else
            expr_mod.evalString(value, ctx);
        const val = eval_result catch |err| blk: {
            error_count.* += 1;
            if (out.debug) {
                if (detail.len > 0) {
                    out.writer.print("[expr error] {s} = \"{s}\": {s} ({s})\n  fields:", .{ key, value, @errorName(err), detail }) catch {};
                } else {
                    out.writer.print("[expr error] {s} = \"{s}\": {s}\n  fields:", .{ key, value, @errorName(err) }) catch {};
                }
                for (ctx.fields) |f| {
                    out.writer.print(" \"{s}\"", .{f}) catch {};
                }
                out.writer.print("\n", .{}) catch {};
                out.writer.flush() catch {};
            }
            out.binEmitErrorRow(source_locator, key, @errorName(err), detail, "input_schema");
            break :blk "";
        };
        try vars.put(key, val);
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
    // skipped: legitimate optional / cross-version columns. A numeric
    // `[4]` is just a header name like any other and is validated the
    // same way (positional access is FIELDS(n), which carries no `[X]`).
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
// the chunk size — not by the file size. A '\n' is an unconditional
// record separator (quoted fields may not span lines — see
// `csv.LineIterator`), so any '\n' is a safe chunk boundary.
//
// The reader itself is `csv.ChunkReader` from the zig-libs `csvstream`
// module — this file used to carry it privately, alongside the record
// iterator that lived in bxp-core. Upstream holds one module for both
// halves.
//
// ONE upstream default is adopted deliberately rather than inherited: the
// `max_record_len` guard. A newline-free input — a single enormous record,
// or a CR-only "classic Mac" file where no '\n' exists at all — used to grow
// the buffer to the whole file size, silently breaking the bounded-memory
// promise this very comment makes. It now fails closed past the chunk size.
// Verified against the pre-migration binary: a 30 MB newline-free file used
// to be buffered whole and converted as one record, and is now refused. This
// is the opposite call from `zipstream`'s output cap (which bxp declines,
// because streaming a multi-GB member is a real use case and costs no
// resident memory) — here the buffer IS resident, so the cap enforces a
// guarantee bxp already advertises. A legitimate CSV record is kilobytes;
// anything past 10 MB on one line is a malformed or non-CSV file.
//
// It is a memory guard, NOT an exact record-size limit, and the diagnostic in
// `nextChunkChecked` is worded accordingly. Upstream tests `buffer.items.len
// >= max_record_len` BEFORE pulling the next read, so a newline-free record
// that starts just under the threshold is still accepted whole: the effective
// ceiling lands somewhere in [max_record_len, ~2 × max_record_len) depending
// on where the record begins relative to a chunk boundary. Bounded memory —
// the property that matters — holds either way.

/// Target chunk size in bytes. The buffer may grow above this for a single
/// long record, but only up to `csv.ChunkReader.max_record_len`.
const CHUNK_SIZE: usize = 10 * 1024 * 1024;

const ChunkReader = csv.ChunkReader;

/// `ChunkReader.nextChunk` with `error.RecordTooLong` translated into a
/// diagnostic the user can act on. Every other error keeps propagating (the
/// top level prints its name). Returns `error.Fatal` after reporting, which
/// main.zig treats as "a diagnostic was already emitted".
fn nextChunkChecked(cr: *ChunkReader, out: Output, name: []const u8) !?[]const u8 {
    return cr.nextChunk() catch |err| switch (err) {
        error.RecordTooLong => {
            // Memory-guard framing, deliberately NOT "records over N MB are
            // refused": the upstream check tests the buffered length BEFORE
            // the next read, so the exact byte at which a newline-free record
            // trips it depends on where the record starts relative to a chunk
            // boundary (anywhere from `max_record_len` to roughly twice it).
            // What IS guaranteed is the property the message states — the
            // reader stops buffering a record that never ends.
            out.fatal(
                "fatal error: '{s}': no line break found in {d} MB of buffered input — the streaming reader " ++
                    "will not keep buffering a single CSV record past that. " ++
                    "Check the file really is CSV, and that it does not use bare CR (classic Mac) line endings\n",
                .{ name, cr.max_record_len / (1024 * 1024) },
            );
            return error.Fatal;
        },
        else => err,
    };
}

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
    filename: []const u8,
    sheet_name: []const u8,
    record_num: u64,
    file_alloc: std.mem.Allocator,
    out: Output,
) !void {
    const pre_ctx = expr_mod.Context{
        .fields = fields,
        .col_index = col_index,
        .quote_out = bc.csv_text_quote_out,
        .maps = &bc.maps,
        .lookup_table = null, // no self-reference during pre_pass
        .alloc = file_alloc,
        .decimal_sep_in = bc.csv_decimal_separator_in,
        .input_encoding = bc.csv_input_encoding,
        .filename = filename,
        .sheet_name = sheet_name,
        .record_num = record_num,
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
            out.binEmitPrepassEntry(pp_name, key_val, ve.key_ptr.*, val);
        }
    }
}

// ─────────────────────── Per-block parallel pipeline ─────────────────────────
//
// `processBroker` accumulates ~10 MiB worth of source-CSV records into a
// `pending_rows` block, then forks K = `runtime.max_workers` worker tasks
// over a contiguous slice of records each. Workers parse fields, evaluate
// `input_schema` + `row_rules`, and emit output bytes + btrace frames into
// per-worker `std.Io.Writer.Allocating` buffers — no shared mutable state
// inside the eval body. After the `std.Io.Group.await` barrier the main thread
// drains the per-worker buffers in worker-index order so the resulting output is
// byte-identical to the single-threaded baseline (the dataset regression
// gate in `scripts/test-07-datasets.sh` catches any divergence for free).
//
// The same fork-join model handles pre_pass: workers populate per-worker
// `partial_lookup` maps; drain merges them into the shared `lookup_table`
// with last-writer-wins semantics (matching serial behaviour where later
// rows overwrite earlier rows for the same composite key).

/// Compile-time inputs to one source-row evaluation. Bundled into a struct
/// so the `evalAndEmitRow` and worker function signatures stay manageable.
/// All fields are read-only references / values — the same `RowEvalConst`
/// instance is shared by every worker in a block.
const RowEvalConst = struct {
    bc: *const config_mod.BrokerConfig,
    col_index: *const std.StringHashMap(usize),
    col_names: []const []const u8,
    lookup_table_ptr: ?*const std.StringHashMap([]const u8),
    single_prepass_name: ?[]const u8,
    date_min: []const u8,
    date_max: []const u8,
    bid: []const u8,
    /// Per-file source context for the FILENAME() / SHEET_NAME() builtins.
    /// `filename` is the input file stem (suffix + directory stripped);
    /// `sheet_name` is the configured `xlsx_sheet.name` for xlsx-derived
    /// input, else "". Both are file-level constants threaded into every
    /// row's `expr.Context`. RECORD_NUM() is threaded separately per row
    /// via the worker's `base_row_idx` (varies within the file).
    filename: []const u8 = "",
    sheet_name: []const u8 = "",
    /// Constant-folded `input_schema` vars: name → precomputed value for every
    /// expression that `expr.isRowInvariant` proved row-invariant and that
    /// evaluated without error at file-start. `evalAllVars` reuses these instead
    /// of re-evaluating per row. `null` on the pre_pass path (no input_schema eval).
    folded_vars: ?*const std.StringHashMap([]const u8) = null,
    /// opt 1: when true, `evalAndEmitRow` evaluates `$date` first and drops
    /// out-of-range rows before input_schema/row_rules. Decided once per file:
    /// requires an active date filter, a declared `$date`, and no rule that
    /// overwrites `$date` (so pre-override `$date` == the value the late filter
    /// would compare). `false` on the pre_pass path.
    date_fast_path: bool = false,
    /// opt 2: per-rule skip-sets, indexed by `row_rules` position. Each set holds
    /// the input_schema var names the rule overwrites in EVERY output row
    /// (intersection across `rule.rows`). When that rule wins, `evalAllVars`
    /// skips those vars' base eval — the override supplies them. Empty on the
    /// pre_pass path.
    rule_skip_sets: []const std.StringHashMap(void) = &.{},
    /// Phase 3B: input_schema expressions precompiled once per file (indexed in
    /// declaration order). `evalAllVars` evaluates these nodes per row instead
    /// of re-parsing the source string each time. `null` on the pre_pass path.
    compiled_schema: ?[]const expr_mod.Node = null,
    /// Phase 3B: row_rules expressions precompiled once per file, indexed by
    /// `row_rules` position. Each `when` + every override value is a compiled
    /// node so the per-row rule walk parses over cached tokens instead of
    /// re-lexing. `null` on the pre_pass path.
    compiled_rules: ?[]const CompiledRule = null,
};

/// Phase 3B: one rule's precompiled expressions. `when` mirrors `rule.when`;
/// `rows[ri]` holds the compiled override-value nodes for the ri-th output row,
/// aligned with that row's `StringArrayHashMap` iteration order.
const CompiledRule = struct {
    when: expr_mod.Node,
    rows: []const []const expr_mod.Node,
};

/// Mutable per-evaluation emit sinks. In the serial path these point at
/// shared file-level state (`fout`, `combined_fout`, `file_rows_written`,
/// `file_expr_errors`, the real `Output` with its btrace writers). In the
/// parallel path each worker passes its own per-worker state — same code
/// path, different destinations, drain re-stitches in source-row order.
const RowEmit = struct {
    out: Output,
    fout: *Writer,
    combined_fout: *Writer,
    combined: bool,
    json_first_row: *bool,
    combined_json_first_row: *bool,
    rows_written: *u64,
    expr_errors: *u32,
};

/// Evaluates one parsed CSV row end-to-end: input_schema variables,
/// row_rules walk (first match wins), per-rule `rows` override eval,
/// date_filter_from_filename gate, output-row write to both per-file and
/// combined sinks, btrace frame emit. Synthesises a `filtered_row` frame
/// when no rule produced any output frame so the GUI sees one row frame
/// per source row.
///
/// The function is shared by the serial path in `processBroker` and the
/// parallel worker function `workerMainPass`. Determinism is provided by
/// passing per-worker sinks + a worker-local `rows_written` counter; the
/// drain step at the end of `processBlockParallel` rewrites btrace
/// `outputIdx` fields to absolute file-scope indices.
fn evalAndEmitRow(
    fields: [][]const u8,
    row_offset: u64,
    record_num: u64,
    rec: *const RowEvalConst,
    line_arena: *std.heap.ArenaAllocator,
    e: *RowEmit,
) !void {
    _ = line_arena.reset(.retain_capacity);
    const line_alloc = line_arena.allocator();
    const bc = rec.bc;
    const out = e.out;
    const delim_out = &[_]u8{bc.csv_delimiter_out};

    var row_detail: []const u8 = "";
    var row_ctx = expr_mod.Context{
        .fields = fields,
        .col_index = rec.col_index,
        .quote_out = bc.csv_text_quote_out,
        .maps = &bc.maps,
        .lookup_table = rec.lookup_table_ptr,
        .single_prepass_name = rec.single_prepass_name,
        .alloc = line_alloc,
        .decimal_sep_in = bc.csv_decimal_separator_in,
        .input_encoding = bc.csv_input_encoding,
        .error_detail = &row_detail,
        .filename = rec.filename,
        .sheet_name = rec.sheet_name,
        .record_num = record_num,
    };

    // opt 1: date-prefilter. When the filter is active and `$date` is declared
    // and never overwritten by a rule (rec.date_fast_path, decided once per
    // file), evaluate `$date` FIRST and drop out-of-range rows before the much
    // costlier input_schema + row_rules evaluation. The drop emits the same
    // `date_filter_from_filename` filtered_row frame the late filter would, but
    // deliberately fires before rule matching — so a date-dropped row is never
    // attributed to `no_rule_match` and never runs per-row eval/error frames.
    if (rec.date_fast_path) {
        row_detail = "";
        const dstr = expr_mod.evalString(bc.input_schema.get(VAR_DATE).?, &row_ctx) catch "";
        if ((rec.date_min.len > 0 and dstr.len >= 10 and
            std.mem.order(u8, dstr[0..10], rec.date_min) == .lt) or
            (rec.date_max.len > 0 and dstr.len >= 10 and
            std.mem.order(u8, dstr[0..10], rec.date_max) == .gt))
        {
            out.binEmitFilteredRow(row_offset, "date_filter_from_filename");
            return;
        }
    }

    const rules = bc.row_rules orelse &.{};

    // opt 2: find the winning rule FIRST. `when` references only CSV columns
    // (never $vars), so rule selection is independent of input_schema — which
    // lets `evalAllVars` then skip computing the input_schema vars the winning
    // rule overwrites in every output row.
    var matched_rule_index: ?usize = null;
    for (rules, 0..) |rule, rule_index| {
        row_detail = "";
        // Phase 3B: evaluate the precompiled `when` node (cached tokens) when
        // available; byte-identical to re-lexing `rule.when`.
        const when_val = (if (rec.compiled_rules) |cr|
            expr_mod.evalNode(&cr[rule_index].when, &row_ctx)
        else
            expr_mod.eval(rule.when, &row_ctx)) catch |err| {
            if (out.debug) {
                if (row_detail.len > 0) {
                    out.writer.print("[row_rules when error] \"{s}\": {s} ({s})\n", .{ rule.when, @errorName(err), row_detail }) catch {};
                } else {
                    out.writer.print("[row_rules when error] \"{s}\": {s}\n", .{ rule.when, @errorName(err) }) catch {};
                }
                out.writer.flush() catch {};
            }
            continue;
        };
        if (when_val.toBool()) {
            matched_rule_index = rule_index;
            break; // first matching rule wins
        }
    }

    // No match → no skip, preserving today's full input_schema eval (and its
    // per-row error frames) for unmatched rows.
    const skip: ?*const std.StringHashMap(void) =
        if (matched_rule_index) |mi| &rec.rule_skip_sets[mi] else null;
    var vars = try evalAllVars(bc.input_schema, &row_ctx, out, e.expr_errors, row_offset, rec.folded_vars, skip, rec.compiled_schema);

    // Track whether this source row produced any row-level bin frame
    // (output_row or filtered_row). If not, we synthesise a `filtered_row`
    // at end-of-row so the GUI's btrace consumer sees one frame per source
    // row. Two miss paths reach here: (a) no rule matched at all, (b) a
    // rule matched but its `rows: []` is empty (silent skip).
    var row_bin_frame_emitted = false;
    if (matched_rule_index) |rule_index| {
        const rule = rules[rule_index];
        for (rule.rows, 0..) |row_override, ri| {
            // Start from base vars, then apply per-row overrides.
            var merged = std.StringHashMap([]const u8).init(line_alloc);
            var base_it = vars.iterator();
            while (base_it.next()) |entry| try merged.put(entry.key_ptr.*, entry.value_ptr.*);
            var ov_it = row_override.iterator();
            var ov_k: usize = 0;
            while (ov_it.next()) |entry| : (ov_k += 1) {
                row_detail = "";
                // Phase 3B: evaluate the precompiled override node when available.
                const val = (if (rec.compiled_rules) |cr|
                    expr_mod.evalNodeString(&cr[rule_index].rows[ri][ov_k], &row_ctx)
                else
                    expr_mod.evalString(entry.value_ptr.*, &row_ctx)) catch |err| blk: {
                    if (out.debug) {
                        if (row_detail.len > 0) {
                            out.writer.print("[row_rules error] {s} = \"{s}\": {s} ({s})\n", .{ entry.key_ptr.*, entry.value_ptr.*, @errorName(err), row_detail }) catch {};
                        } else {
                            out.writer.print("[row_rules error] {s} = \"{s}\": {s}\n", .{ entry.key_ptr.*, entry.value_ptr.*, @errorName(err) }) catch {};
                        }
                        out.writer.flush() catch {};
                    }
                    out.binEmitErrorRow(row_offset, entry.key_ptr.*, @errorName(err), row_detail, "row_rules");
                    break :blk "";
                };
                try merged.put(entry.key_ptr.*, val);
            }
            // Date range filter (date_filter_from_filename). Lexical prefix
            // compare on the first 10 bytes of $date — ISO-8601 datetime
            // strings sort chronologically as plain ASCII. Skipping when
            // $date is shorter than 10 bytes passes the row through
            // unfiltered rather than silently dropping it.
            const date_str = merged.get(VAR_DATE) orelse "";
            if (rec.date_min.len > 0 and date_str.len >= 10 and
                std.mem.order(u8, date_str[0..10], rec.date_min) == .lt) {
                out.binEmitFilteredRow(row_offset, "date_filter_from_filename");
                row_bin_frame_emitted = true;
                continue;
            }
            if (rec.date_max.len > 0 and date_str.len >= 10 and
                std.mem.order(u8, date_str[0..10], rec.date_max) == .gt) {
                out.binEmitFilteredRow(row_offset, "date_filter_from_filename");
                row_bin_frame_emitted = true;
                continue;
            }
            if (bc.file_type_out == .json) {
                if (!e.json_first_row.*) try e.fout.writeAll(",\n");
                e.json_first_row.* = false;
                try writeJsonRow(e.fout, bc.output_schema.items, &merged);
                if (e.combined) {
                    if (!e.combined_json_first_row.*) try e.combined_fout.writeAll(",\n");
                    e.combined_json_first_row.* = false;
                    try writeJsonRow(e.combined_fout, bc.output_schema.items, &merged);
                }
            } else {
                // Layer 0 output: transcode each UTF-8 cell to the configured
                // output code page before the RFC-4180 quoting. The delimiter,
                // quotes, CR/LF and decimal separator are all ASCII (identical
                // in every target code page), so writeSafeValue's structural
                // logic is unaffected by working on transcoded bytes.
                const out_enc = bc.csv_output_encoding;
                var val_buf: [VAL_BUF_SIZE]u8 = undefined;
                for (bc.output_schema.items, 0..) |col, ci| {
                    if (ci > 0) try e.fout.writeAll(delim_out);
                    const cell = try encodeOutCell(line_alloc, merged.get(col.variable) orelse "", out_enc);
                    try writeSafeValue(e.fout, cell, bc.csv_delimiter_out, bc.csv_decimal_separator_out, bc.csv_text_quote_out, &val_buf);
                }
                try e.fout.writeAll("\n");
                if (e.combined) {
                    var val_buf2: [VAL_BUF_SIZE]u8 = undefined;
                    for (bc.output_schema.items, 0..) |col, ci| {
                        if (ci > 0) try e.combined_fout.writeAll(delim_out);
                        const cell = try encodeOutCell(line_alloc, merged.get(col.variable) orelse "", out_enc);
                        try writeSafeValue(e.combined_fout, cell, bc.csv_delimiter_out, bc.csv_decimal_separator_out, bc.csv_text_quote_out, &val_buf2);
                    }
                    try e.combined_fout.writeAll("\n");
                }
            }
            // Bin protocol: one output_row frame per written output. In
            // worker context `rows_written` is the per-slice local counter;
            // `processBlockParallel` drain rewrites these to absolute
            // file-scope indices via the btrace bytes patch step.
            out.binEmitOutputRow(
                row_offset,
                e.rows_written.*,
                @intCast(rule_index),
                merged.get("$action") orelse "",
            );
            row_bin_frame_emitted = true;
            e.rows_written.* += 1;
        }
    }
    if (matched_rule_index == null) {
        if (bc.row_rules_debug_missing and out.debug) {
            out.writer.print("[{s}] unmatched row (no row_rules entry):\n{{\n", .{rec.bid}) catch {};
            for (rec.col_names, 0..) |col_name, ci| {
                const val = if (ci < fields.len) fields[ci] else "";
                const sep: []const u8 = if (ci + 1 < rec.col_names.len) "," else "";
                out.writer.print("  \"{s}\": \"{s}\"{s}\n", .{ col_name, val, sep }) catch {};
            }
            out.writer.print("}}\n", .{}) catch {};
            out.writer.flush() catch {};
        }
    }
    // Synthetic filtered_row so the GUI sees one row frame per source row
    // (btrace v3 has no per-source-row frame by default). Reasons:
    //   - "no_rule_match"  → no rule's `when` evaluated truthy
    //   - "rule_skip"      → a rule matched but its rows: [] is empty
    if (!row_bin_frame_emitted) {
        const reason: []const u8 = if (matched_rule_index != null) "rule_skip" else "no_rule_match";
        out.binEmitFilteredRow(row_offset, reason);
    }
}

/// One pre-parsed JSON record handed to a worker for evaluation. Field
/// slices are allocated by the producer thread (the serial Scanner-based
/// `RecordReader`) into a caller-owned block arena that stays live
/// through the parallel block's `std.Io.Group.await` barrier.
pub const ParsedJsonRecord = struct {
    fields: [][]const u8,
    byte_offset: u64,
};

/// Per-worker scratch + output buffers used by the per-block parallel
/// pipeline. A fixed array of `WorkerSlice` is allocated once per file
/// (size = `runtime.max_workers`), reused across every block within the
/// file, and deinit'd at file end. Per-block reset clears the eval/IO
/// state but keeps the underlying ArrayList capacity to avoid mmap churn
/// on the next block; `prepass_arena` is reset only at file boundaries
/// because the bytes it allocates feed the shared `lookup_table` and
/// must outlive the pre_pass barrier.
const WorkerSlice = struct {
    // === Input slice (set by the per-block orchestrator) ===
    lines: []const csv.LineSlice = &.{},

    // === JSON parallel input (mutually exclusive with `lines`) ===
    /// JSON main/pre_pass workers consume pre-parsed records here instead
    /// of raw CSV bytes — parsing JSON in workers would require carrying
    /// per-worker Scanner state and a brace-aware byte splitter; serial
    /// parsing in the reader thread is much simpler and the eval step
    /// (where 3-expr templates spend the bulk of CPU) still parallelises.
    /// Pre-parsed records' field slices live in the caller-owned block
    /// arena and stay valid through the `std.Io.Group.await` barrier.
    json_records: []const ParsedJsonRecord = &.{},
    base_row_idx: u64 = 0,

    // === Per-block scratch (reset between blocks within a file) ===
    line_arena: std.heap.ArenaAllocator,
    field_arena: std.heap.ArenaAllocator,
    field_buf: []u8 = &.{}, // reusable [][]const u8 storage (alloc'd at init)

    // === Per-file scratch (reset only at file boundaries) ===
    /// Backs the per-worker pre_pass `partial_lookup` entries (composite
    /// key + value bytes). Drain merges by copying pointers into the
    /// shared `lookup_table`, so these bytes must live until the file's
    /// main pass is done.
    prepass_arena: std.heap.ArenaAllocator,

    // === Per-worker IO buffers (cleared per block) ===
    out_alloc: std.Io.Writer.Allocating,
    combined_alloc: std.Io.Writer.Allocating,
    btrace_alloc: std.Io.Writer.Allocating,
    debug_alloc: std.Io.Writer.Allocating,
    btw: btrace.Writer, // wraps `&btrace_alloc.writer`; no magic write
    worker_out: Output, // synthetic Output backed by the per-worker buffers

    // === JSON serialization state (worker-local within a block) ===
    json_first_row: bool = true,
    combined_json_first_row: bool = true,

    // === Counters ===
    rows_written: u64 = 0, // local outputIdx counter; drain patches to absolute
    expr_errors: u32 = 0,

    // === Pre_pass state ===
    /// Populated by `workerPrePass`; drained into the shared
    /// `lookup_table` after the `std.Io.Group.await` barrier.
    partial_lookup: std.StringHashMap([]const u8),

    // === Error state (Io.Group async tasks can't propagate errors out) ===
    error_value: ?anyerror = null,

    /// Initialise `self` in its final storage location. Cannot return by
    /// value: `worker_out.writer` and `btw.w` are self-referential
    /// pointers into `debug_alloc.writer` / `btrace_alloc.writer`, so
    /// returning a copy of the struct would leave the pointers aimed at
    /// the temporary stack slot instead of the caller's array element.
    /// Caller pattern:
    ///
    ///     workers[i] = undefined;
    ///     try workers[i].init(alloc);
    pub fn init(self: *WorkerSlice, alloc: std.mem.Allocator) !void {
        self.* = WorkerSlice{
            .line_arena = std.heap.ArenaAllocator.init(alloc),
            .field_arena = std.heap.ArenaAllocator.init(alloc),
            .field_buf = &.{}, // alloc'd below
            .prepass_arena = std.heap.ArenaAllocator.init(alloc),
            .out_alloc = std.Io.Writer.Allocating.init(alloc),
            .combined_alloc = std.Io.Writer.Allocating.init(alloc),
            .btrace_alloc = std.Io.Writer.Allocating.init(alloc),
            .debug_alloc = std.Io.Writer.Allocating.init(alloc),
            .btw = undefined,
            .worker_out = undefined,
            .partial_lookup = std.StringHashMap([]const u8).init(alloc),
        };
        // Field buffer is `[MAX_COLUMNS][]const u8` worth of pointer
        // slots. splitFields writes slice headers into it; the
        // underlying bytes either point into the source chunk or live in
        // `field_arena`.
        self.field_buf = try alloc.alloc(u8, @sizeOf([]const u8) * MAX_COLUMNS);
        // We construct `btw` directly (bypassing `btrace.Writer.init`)
        // so it does NOT write the BXTB magic into the per-worker buffer.
        // Magic is emitted exactly once per stream by main.zig at startup;
        // worker bytes are appended raw after that. `chunk_id = 0` matches
        // the value the canonical writer carries (reserved for future
        // multicore chunk dispatch — always 0 today; see btrace.zig).
        self.btw = .{ .w = &self.btrace_alloc.writer, .chunk_id = 0 };
        self.worker_out = Output{
            .writer = &self.debug_alloc.writer,
            .quiet = false,
            .debug = false, // set per call via setDebug()
            .trace = .off,
            .dry_run = false,
            .btrace_writer = &self.btw,
            .btrace_file_writer = null,
        };
    }

    pub fn deinit(self: *WorkerSlice) void {
        const alloc = self.line_arena.child_allocator;
        self.line_arena.deinit();
        self.field_arena.deinit();
        self.prepass_arena.deinit();
        self.out_alloc.deinit();
        self.combined_alloc.deinit();
        self.btrace_alloc.deinit();
        self.debug_alloc.deinit();
        self.partial_lookup.deinit();
        alloc.free(self.field_buf);
    }

    pub fn setDebug(self: *WorkerSlice, debug: bool) void {
        self.worker_out.debug = debug;
    }

    /// Enable or disable per-worker btrace frame emission. When the real
    /// `Output` has both `btrace_writer` and `btrace_file_writer` as
    /// null (trace=off, no --trace-file), workers would otherwise emit
    /// every frame into their per-worker `btrace_alloc` buffer only for
    /// the drain step to patch + drop the bytes. Routing
    /// `worker_out.btrace_writer = null` for the no-trace case makes
    /// the `Output.binEmit*` calls inside `evalAndEmitRow` no-op via
    /// their `if (self.btrace_writer) |bw|` guard — the inner btrace
    /// frame serialization (length-prefixed strings, Allocating
    /// growth, etc.) is skipped entirely. Measured wall-time win is
    /// significant on row-heavy + narrow-column workloads where the
    /// per-row eval is light and the wasted btrace serialization
    /// dominates the worker loop.
    pub fn setBtraceEnabled(self: *WorkerSlice, enabled: bool) void {
        self.worker_out.btrace_writer = if (enabled) &self.btw else null;
    }

    /// Clear per-block state. Called by the orchestrator before each
    /// block dispatch. Areny use `.retain_capacity` so the pages stay
    /// mmapped; buffers reset length to 0 but keep their underlying
    /// allocation. `prepass_arena` and `partial_lookup` are NOT reset
    /// here — they live across blocks within a file (pre_pass populates
    /// across the whole file, main pass consumes via shared lookup_table).
    pub fn resetForBlock(self: *WorkerSlice) void {
        _ = self.line_arena.reset(.retain_capacity);
        _ = self.field_arena.reset(.retain_capacity);
        self.out_alloc.clearRetainingCapacity();
        self.combined_alloc.clearRetainingCapacity();
        self.btrace_alloc.clearRetainingCapacity();
        self.debug_alloc.clearRetainingCapacity();
        self.json_first_row = true;
        self.combined_json_first_row = true;
        self.rows_written = 0;
        self.expr_errors = 0;
        self.error_value = null;
        self.base_row_idx = 0; // orchestrator sets the real per-slice base
    }

    /// Clear per-file state. Called by the orchestrator at file
    /// boundaries (before processing the first block of a new file).
    pub fn resetForFile(self: *WorkerSlice) void {
        _ = self.prepass_arena.reset(.retain_capacity);
        self.partial_lookup.clearRetainingCapacity();
        self.resetForBlock();
    }

    /// Typed view of `field_buf` as a `[][]const u8` slice for splitFields.
    ///
    /// Sized at exactly `MAX_COLUMNS` slots: `csv.splitFields` stops at the
    /// buffer bound and silently drops any further fields. This is an
    /// intentional asymmetry with the header path — `parseCsvHeader` sizes its
    /// scratch at `MAX_COLUMNS + 1` precisely to detect and WARN on an
    /// over-wide header — whereas a body row wider than `MAX_COLUMNS`
    /// truncates without a diagnostic (data-lenient: columns past the capped
    /// header aren't name-addressable anyway, so the header warning already
    /// flags that file). If `MAX_COLUMNS` ever changes, keep these two paths'
    /// over-width handling in sync.
    inline fn fieldBufSlice(self: *WorkerSlice) [][]const u8 {
        const ptr: [*][]const u8 = @ptrCast(@alignCast(self.field_buf.ptr));
        return ptr[0..MAX_COLUMNS];
    }
};

/// Main-pass worker: parses each line in `ws.lines` and routes the row
/// through `evalAndEmitRow` with per-worker emit sinks. Output bytes,
/// combined-sink bytes, btrace frame bytes (with **local** outputIdx),
/// and debug-print bytes all land in per-worker buffers that the drain
/// step concatenates in source-row order.
fn workerMainPass(ws: *WorkerSlice, rec: *const RowEvalConst) void {
    var emit = RowEmit{
        .out = ws.worker_out,
        .fout = &ws.out_alloc.writer,
        .combined_fout = &ws.combined_alloc.writer,
        .combined = rec.bc.combined_output,
        .json_first_row = &ws.json_first_row,
        .combined_json_first_row = &ws.combined_json_first_row,
        .rows_written = &ws.rows_written,
        .expr_errors = &ws.expr_errors,
    };
    const field_slice = ws.fieldBufSlice();
    for (ws.lines, 0..) |line, j| {
        _ = ws.field_arena.reset(.retain_capacity);
        const fields = csv.splitFields(
            line.bytes,
            field_slice,
            rec.bc.csv_delimiter_in,
            rec.bc.csv_text_quote_in,
            ws.field_arena.allocator(),
        ) catch |err| {
            ws.error_value = err;
            return;
        };
        // 1-based input record number within the file (RECORD_NUM()): this
        // worker's slice base + local row index.
        evalAndEmitRow(fields, line.byte_offset, ws.base_row_idx + j + 1, rec, &ws.line_arena, &emit) catch |err| {
            ws.error_value = err;
            return;
        };
    }
}

/// JSON main-pass worker: consumes pre-parsed records in `ws.json_records`
/// and routes each through `evalAndEmitRow`. No `csv.splitFields` step —
/// the producer thread (RecordReader) already materialised every field.
fn workerJsonMainPass(ws: *WorkerSlice, rec: *const RowEvalConst) void {
    var emit = RowEmit{
        .out = ws.worker_out,
        .fout = &ws.out_alloc.writer,
        .combined_fout = &ws.combined_alloc.writer,
        .combined = rec.bc.combined_output,
        .json_first_row = &ws.json_first_row,
        .combined_json_first_row = &ws.combined_json_first_row,
        .rows_written = &ws.rows_written,
        .expr_errors = &ws.expr_errors,
    };
    for (ws.json_records, 0..) |rrec, j| {
        evalAndEmitRow(rrec.fields, rrec.byte_offset, ws.base_row_idx + j + 1, rec, &ws.line_arena, &emit) catch |err| {
            ws.error_value = err;
            return;
        };
    }
}

/// JSON pre_pass worker: same idea as `workerPrePass` but skips field
/// parsing (records arrive pre-parsed from the serial Scanner reader).
fn workerJsonPrePass(ws: *WorkerSlice, rec: *const RowEvalConst) void {
    for (ws.json_records, 0..) |rrec, j| {
        evalPrepassRow(
            rrec.fields,
            rec.col_index,
            &ws.partial_lookup,
            rec.bc,
            rec.filename,
            rec.sheet_name,
            ws.base_row_idx + j + 1,
            ws.prepass_arena.allocator(),
            ws.worker_out,
        ) catch |err| {
            ws.error_value = err;
            return;
        };
    }
}

/// Upper bound on per-block worker count. Sizes the stack-allocated
/// `boundaries` array in `processBlockParallel`. `main.zig` clamps the
/// CPU-derived worker count to this before constructing the Runtime, so
/// a host with more than this many logical CPUs caps parallel fan-out
/// here instead of aborting (serial-equivalent output is unchanged — `K`
/// only governs fan-out). If this ever needs to grow past a stack-array
/// size that's comfortable, swap the array for a heap allocation.
pub const MAX_WORKERS_LIMIT: usize = 256;

/// In-place rewrite of the `outputIdx` u64 field in every `output_row`
/// frame within `bytes`. Each worker emits its frames with a per-slice
/// LOCAL `outputIdx` (0..ws.rows_written); the drain step adds
/// `slice_base` (cumulative `file_rows_written` from previously-drained
/// workers + this file's pre-block total) so the bytes appended to the
/// real btrace stream carry absolute file-scope indices — byte-identical
/// to the single-threaded baseline.
///
/// Frame layout (see bxp-core/src/btrace.zig writeOutputRow):
///
///     [1B type=0x03][2B chunk_id][4B pay_len]
///     [8B source_locator][8B output_idx ← patched][4B rule_idx]
///     [4B action_len][N bytes action]
///
/// `output_idx` sits at `frame_start + 1 + 2 + 4 + 8 = 15`.
///
/// Defensive truncation check: a partial frame at the tail breaks the
/// loop early. Workers never emit a truncated frame (each writeOutputRow
/// is a single bounded call), but the check costs nothing and guards
/// against silent bit-shifted patches if a future frame layout change
/// breaks the assumed `pay_len` length.
fn patchBtraceOutputIdx(bytes: []u8, slice_base: u64) void {
    const output_row_byte: u8 = @intFromEnum(btrace.FrameType.output_row);
    var pos: usize = 0;
    while (pos + 7 <= bytes.len) {
        const t = bytes[pos];
        const pay_len = std.mem.readInt(u32, bytes[pos + 3 ..][0..4], .little);
        const frame_end = pos + 7 + pay_len;
        if (frame_end > bytes.len) break;
        if (t == output_row_byte) {
            const idx_off = pos + 15;
            const cur = std.mem.readInt(u64, bytes[idx_off..][0..8], .little);
            std.mem.writeInt(u64, bytes[idx_off..][0..8], cur + slice_base, .little);
        }
        pos = frame_end;
    }
}

/// Per-block parallel orchestrator. Splits the input `lines` slice into
/// K contiguous row slices (K = min(`runtime.max_workers`, `lines.len`)),
/// assigns each to a `WorkerSlice` from the caller-owned pool, forks K
/// worker tasks via `std.Io.Group.async`, and waits on the `Group.await`
/// barrier. The caller drains per-worker buffers in worker-index order via
/// `drainBlockMain` or `drainBlockPrePass`.
///
/// Row-count split (not byte-count): each worker gets `lines.len / K`
/// rows, with the remainder spread across the first `lines.len % K`
/// workers. Source-row contiguity is preserved (slice 0 = rows 0..n0,
/// slice 1 = rows n0..n1, etc.), so the drain-in-order step yields
/// output that matches the single-threaded baseline byte-for-byte.
fn processBlockParallel(
    lines: []const csv.LineSlice,
    workers: []WorkerSlice,
    runtime: Runtime,
    rec: *const RowEvalConst,
    is_prepass: bool,
    block_base: u64,
) !usize {
    if (lines.len == 0) return 0;
    const k_raw = @min(runtime.max_workers, lines.len);
    if (k_raw > MAX_WORKERS_LIMIT) return error.TooManyWorkers;
    const K = k_raw;

    var boundaries: [MAX_WORKERS_LIMIT + 1]usize = undefined;
    boundaries[0] = 0;
    const base = lines.len / K;
    const rem = lines.len % K;
    for (0..K) |i| {
        const slice_len = base + (if (i < rem) @as(usize, 1) else @as(usize, 0));
        boundaries[i + 1] = boundaries[i] + slice_len;
    }

    for (workers[0..K], 0..) |*w, i| {
        w.resetForBlock();
        w.lines = lines[boundaries[i]..boundaries[i + 1]];
        // 0-based count of records before this slice in the file → RECORD_NUM().
        w.base_row_idx = block_base + boundaries[i];
    }

    var g: std.Io.Group = .init;
    if (is_prepass) {
        for (workers[0..K]) |*w| g.async(runtime.io, workerPrePass, .{ w, rec });
    } else {
        for (workers[0..K]) |*w| g.async(runtime.io, workerMainPass, .{ w, rec });
    }
    g.await(runtime.io) catch {};

    // Surface the first worker error encountered. Workers cannot
    // propagate errors out through `std.Io.Group.async` so they stash them in
    // `error_value`; we re-raise here so the file loop's main-thread
    // error path handles it the same way as the serial path would.
    for (workers[0..K]) |*w| {
        if (w.error_value) |err| return err;
    }
    return K;
}

/// JSON sibling of `processBlockParallel`. Splits the pre-parsed records
/// slice into K contiguous worker slices (same row-count split as the
/// CSV path) and dispatches `workerJsonMainPass` / `workerJsonPrePass`.
/// Caller drains via `drainBlockMain` / `drainBlockPrePass` exactly the
/// same way as the CSV path — the per-worker output buffers are format-
/// agnostic.
fn processBlockParallelJson(
    records: []const ParsedJsonRecord,
    workers: []WorkerSlice,
    runtime: Runtime,
    rec: *const RowEvalConst,
    is_prepass: bool,
    block_base: u64,
) !usize {
    if (records.len == 0) return 0;
    const k_raw = @min(runtime.max_workers, records.len);
    if (k_raw > MAX_WORKERS_LIMIT) return error.TooManyWorkers;
    const K = k_raw;

    var boundaries: [MAX_WORKERS_LIMIT + 1]usize = undefined;
    boundaries[0] = 0;
    const base = records.len / K;
    const rem = records.len % K;
    for (0..K) |i| {
        const slice_len = base + (if (i < rem) @as(usize, 1) else @as(usize, 0));
        boundaries[i + 1] = boundaries[i] + slice_len;
    }

    for (workers[0..K], 0..) |*w, i| {
        w.resetForBlock();
        w.json_records = records[boundaries[i]..boundaries[i + 1]];
        // 0-based count of records before this slice in the file → RECORD_NUM().
        w.base_row_idx = block_base + boundaries[i];
    }

    var g: std.Io.Group = .init;
    if (is_prepass) {
        for (workers[0..K]) |*w| g.async(runtime.io, workerJsonPrePass, .{ w, rec });
    } else {
        for (workers[0..K]) |*w| g.async(runtime.io, workerJsonMainPass, .{ w, rec });
    }
    g.await(runtime.io) catch {};

    for (workers[0..K]) |*w| {
        if (w.error_value) |err| return err;
    }
    return K;
}

/// Parses the CSV header (first logical record) from the first chunk
/// returned by a `ChunkReader`. Strips a UTF-8 BOM, splits the header
/// fields, dupes them into `file_alloc` after trimming spaces, and
/// populates `col_index` + `col_names`. Returns the byte offset within
/// `chunk_bytes` where body records begin — the caller continues
/// iteration from there with `csv.LineIterator`. Header truncation
/// (more than `MAX_COLUMNS`) bumps `stats.warnings` and emits a warning.
fn parseCsvHeader(
    chunk_bytes: []const u8,
    delimiter: u8,
    quote: u8,
    header_line: u32,
    input_encoding: encoding.Encoding,
    file_alloc: std.mem.Allocator,
    col_index: *std.StringHashMap(usize),
    col_names: *std.array_list.Managed([]const u8),
    out: Output,
    filename: []const u8,
    stats: *SectionStats,
) !usize {
    var pos: usize = 0;
    if (chunk_bytes.len >= 3 and std.mem.eql(u8, chunk_bytes[0..3], "\xEF\xBB\xBF")) {
        pos = 3;
    }
    // Headerless input (csv_header_line = 0): consume no line as headers, leave
    // col_index empty, and let body iteration start at the very first line —
    // columns are reachable only by position via FIELDS(n).
    if (header_line == 0) return pos;
    var hdr_it = csv.LineIterator.init(chunk_bytes[pos..], quote, 0);
    // Skip the header_line-1 preamble lines that precede the header row.
    var preamble: u32 = 1;
    while (preamble < header_line) : (preamble += 1) {
        if (hdr_it.next() == null) return pos + hdr_it.pos; // ran out before the header → no body
    }
    const hdr_line_opt = hdr_it.next();
    if (hdr_line_opt == null) return pos + hdr_it.pos;
    const hdr_line = hdr_line_opt.?;
    var hdr_arena = std.heap.ArenaAllocator.init(file_alloc);
    defer hdr_arena.deinit();
    const hdr_scratch = try hdr_arena.allocator().alloc([]const u8, MAX_COLUMNS + 1);
    const raw_header = try csv.splitFields(hdr_line.bytes, hdr_scratch, delimiter, quote, hdr_arena.allocator());
    const truncated = raw_header.len > MAX_COLUMNS;
    const header_fields = if (truncated) raw_header[0..MAX_COLUMNS] else raw_header;
    if (truncated) {
        stats.warnings += 1;
        out.warning("warning: '{s}' has more than {d} columns; extra columns are ignored\n", .{ filename, MAX_COLUMNS });
    }
    for (header_fields, 0..) |name, idx| {
        const trimmed = std.mem.trim(u8, name, " ");
        // Layer 0: transcode header names to UTF-8 too, so they match the
        // UTF-8 [ColumnName] references from the (always-UTF-8) config file.
        const owned = if (input_encoding == .utf8)
            try file_alloc.dupe(u8, trimmed)
        else
            try encoding.decodeToUtf8(file_alloc, trimmed, input_encoding);
        // Duplicate header names resolve last-wins: a later `[Name]` reference
        // picks the rightmost column. Kept for back-compat; flagged below.
        try col_index.put(owned, idx);
        try col_names.append(owned);
    }

    // Warn about duplicate header names. `[Name]` resolves last-wins via
    // col_index (above), but every column stays reachable positionally through
    // FIELDS(n) — so the warning names the exact 1-based columns and which one
    // `[Name]` reads, letting the user either fix the header or read a shadowed
    // column with FIELDS(n). Empty header cells (trailing delimiters) aren't
    // addressable by name, so repeats there mask nothing and stay silent. The
    // scan is O(cols^2) but only runs when a duplicate exists, and cols is
    // bounded by MAX_COLUMNS.
    var dup_warned = std.StringHashMap(void).init(hdr_arena.allocator());
    for (col_names.items) |dname| {
        if (dname.len == 0 or dup_warned.contains(dname)) continue;
        var cols = std.Io.Writer.Allocating.init(hdr_arena.allocator());
        var count: usize = 0;
        var last_col: usize = 0;
        for (col_names.items, 0..) |other, j| {
            if (!std.mem.eql(u8, other, dname)) continue;
            if (count > 0) cols.writer.writeAll(", ") catch {};
            cols.writer.print("{d}", .{j + 1}) catch {};
            count += 1;
            last_col = j + 1;
        }
        if (count < 2) continue;
        try dup_warned.put(dname, {});
        stats.warnings += 1;
        out.warning(
            "warning: '{s}' has a duplicate column header '{s}' at columns {s}; [{s}] reads column {d} — use FIELDS(n) to read the others\n",
            .{ filename, dname, cols.written(), dname, last_col },
        );
    }
    return pos + hdr_it.pos;
}

/// BOM + first-record skip without parsing fields or populating
/// `col_index`. Used by the parallel CSV main pass to skip the header
/// line in the first chunk after the file is re-opened for the second
/// pass (the pre_pass already populated `col_index` + `col_names`, no
/// need to redo it).
fn skipBomAndHeader(chunk_bytes: []const u8, quote: u8, header_line: u32) usize {
    var pos: usize = 0;
    if (chunk_bytes.len >= 3 and std.mem.eql(u8, chunk_bytes[0..3], "\xEF\xBB\xBF")) {
        pos = 3;
    }
    // Headerless: no line was consumed as headers, so body starts at the first line.
    if (header_line == 0) return pos;
    // Skip the preamble lines plus the header row (header_line lines total).
    var it = csv.LineIterator.init(chunk_bytes[pos..], quote, 0);
    var n: u32 = 0;
    while (n < header_line) : (n += 1) {
        if (it.next() == null) return chunk_bytes.len;
    }
    return pos + it.pos;
}

/// Drains K main-pass workers in worker-index order into the real
/// per-file sink + combined sink + btrace stream, patches per-worker
/// btrace bytes with the absolute file-scope `outputIdx`, and
/// accumulates per-worker counters into the file-level totals.
fn drainBlockMain(
    workers: []WorkerSlice,
    K: usize,
    file_type_out: config_mod.FileType,
    combined: bool,
    real_fout: *Writer,
    real_combined_fout: *Writer,
    file_json_first_row: *bool,
    file_combined_json_first_row: *bool,
    real_out: Output,
    file_rows_written: *u64,
    file_expr_errors: *u32,
) !void {
    for (workers[0..K]) |*w| {
        const out_bytes = w.out_alloc.written();
        const combined_bytes = w.combined_alloc.written();
        const btrace_bytes = w.btrace_alloc.written();
        const debug_bytes = w.debug_alloc.written();

        // Per-file output sink. JSON inserts a `,\n` separator before
        // this worker's bytes when the file has already emitted at least
        // one row (the very first worker with any output triggers the
        // `file_json_first_row` flip).
        if (out_bytes.len > 0) {
            if (file_type_out == .json) {
                if (!file_json_first_row.*) try real_fout.writeAll(",\n");
                file_json_first_row.* = false;
            }
            try real_fout.writeAll(out_bytes);
        }
        // Combined sink (same logic on its own `first_row` flag spanning
        // every input file in the template).
        if (combined and combined_bytes.len > 0) {
            if (file_type_out == .json) {
                if (!file_combined_json_first_row.*) try real_combined_fout.writeAll(",\n");
                file_combined_json_first_row.* = false;
            }
            try real_combined_fout.writeAll(combined_bytes);
        }
        // Btrace: patch outputIdx in place to absolute file-scope index,
        // then append the same bytes to both real sinks (stdout stream
        // and `--trace-file` sidecar when present).
        if (btrace_bytes.len > 0) {
            patchBtraceOutputIdx(btrace_bytes, file_rows_written.*);
            if (real_out.btrace_writer) |bw| try bw.w.writeAll(btrace_bytes);
            if (real_out.btrace_file_writer) |bw| try bw.w.writeAll(btrace_bytes);
        }
        file_rows_written.* += w.rows_written;
        file_expr_errors.* += w.expr_errors;
        // Debug prints land in real stdout (same destination as serial
        // path; --debug and --trace are mutually exclusive via main.zig).
        if (debug_bytes.len > 0) {
            real_out.writer.writeAll(debug_bytes) catch {};
            real_out.writer.flush() catch {};
        }
    }
}

/// Drains K pre_pass workers: merges per-worker `partial_lookup` maps
/// into the shared `lookup_table` (last-writer-wins on duplicate
/// composite keys, matching serial semantics), then appends per-worker
/// btrace bytes (only `prepass_entry` frames — no outputIdx patching
/// needed) and debug bytes to the real sinks.
fn drainBlockPrePass(
    workers: []WorkerSlice,
    K: usize,
    real_out: Output,
    shared_lookup_table: *std.StringHashMap([]const u8),
) !void {
    for (workers[0..K]) |*w| {
        const btrace_bytes = w.btrace_alloc.written();
        const debug_bytes = w.debug_alloc.written();

        if (btrace_bytes.len > 0) {
            if (real_out.btrace_writer) |bw| try bw.w.writeAll(btrace_bytes);
            if (real_out.btrace_file_writer) |bw| try bw.w.writeAll(btrace_bytes);
        }
        var it = w.partial_lookup.iterator();
        while (it.next()) |entry| {
            try shared_lookup_table.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        if (debug_bytes.len > 0) {
            real_out.writer.writeAll(debug_bytes) catch {};
            real_out.writer.flush() catch {};
        }
    }
}

/// Pre_pass worker: parses each line and runs `evalPrepassRow` against a
/// per-worker `partial_lookup` map. Drain merges the partial maps into
/// the shared `lookup_table` (last-writer-wins on duplicate composite
/// keys, matching serial semantics). Bytes for composite keys + values
/// allocate from `ws.prepass_arena` so they survive past the pre_pass
/// barrier into the main pass.
fn workerPrePass(ws: *WorkerSlice, rec: *const RowEvalConst) void {
    const field_slice = ws.fieldBufSlice();
    for (ws.lines, 0..) |line, j| {
        _ = ws.field_arena.reset(.retain_capacity);
        const fields = csv.splitFields(
            line.bytes,
            field_slice,
            rec.bc.csv_delimiter_in,
            rec.bc.csv_text_quote_in,
            ws.field_arena.allocator(),
        ) catch |err| {
            ws.error_value = err;
            return;
        };
        evalPrepassRow(
            fields,
            rec.col_index,
            &ws.partial_lookup,
            rec.bc,
            rec.filename,
            rec.sheet_name,
            ws.base_row_idx + j + 1,
            ws.prepass_arena.allocator(),
            ws.worker_out,
        ) catch |err| {
            ws.error_value = err;
            return;
        };
    }
}

/// Processes all matching input files in dir_path for the given template.
/// For each file:
///   1. Extracts optional date range from the filename.
///   2. Streams the input (CSV or JSON) in 10 MiB chunks; builds col_index from the header/keys.
///   3. Builds pre_pass lookup table if configured (streaming first pass over the file).
///   4. Evaluates input_schema expressions per row and writes output (CSV or JSON).
/// Returns accumulated SectionStats for this template.
///
/// REFACTOR NOTE (2026-06-13 audit): this function is long (~930 lines) and a
/// future cleanup could lift the combined-output bookkeeping into a small
/// `CombinedSink` struct (open/header/flush/close) and the per-file body into
/// a `processOneFile` helper. Deliberately NOT done now: it is pure
/// reorganisation with no behaviour change, and the win (readability) did not
/// justify the regression risk while the combined-output path had no test
/// gate. That gate now exists (`datasets/combined_output_demo`), so a future
/// split is safer — take it on only with a concrete maintenance need, and
/// keep test-02 (datasets) + test-06 (corpus) byte-green across the change.
pub fn processBroker(
    bid: []const u8,
    dir_path: []const u8,
    bc: *const config_mod.BrokerConfig,
    fresh: bool,
    out_in: Output,
    runtime: Runtime,
    alloc: std.mem.Allocator,
) !SectionStats {
    var stats = SectionStats{};
    var timer = Timer.begin(runtime.io);

    out_in.info("\n=== template: {s} ===\n", .{bid});

    const out = out_in;

    // Worker scratch — one `WorkerSlice` per pool worker, allocated once
    // per template and reused across every file. `resetForFile` clears
    // per-file state (`prepass_arena`, `partial_lookup`) at each file
    // boundary; `processBlockParallel` calls `resetForBlock` per block.
    // `inited` tracks how many were successfully constructed so the
    // single defer below deinits exactly the constructed ones even if
    // initialization fails partway through.
    const K_workers = runtime.max_workers;
    const workers = try alloc.alloc(WorkerSlice, K_workers);
    var workers_inited: usize = 0;
    defer {
        var i = workers_inited;
        while (i > 0) : (i -= 1) workers[i - 1].deinit();
        alloc.free(workers);
    }
    for (workers) |*w| {
        w.* = undefined;
        try w.init(alloc);
        workers_inited += 1;
    }

    // LOOKUP-without-pre_pass guard: inspect.annotateRaw catches this at
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
    var dir = std.Io.Dir.cwd().openDir(runtime.io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            out.fatal("error: directory not found: '{s}'\n", .{dir_path});
            stats.has_fatal = true;
            stats.time_ns = timer.read();
            return stats;
        }
        return err;
    };
    defer dir.close(runtime.io);

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
        while (try it.next(runtime.io)) |entry| {
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
    var combined_out_file: std.Io.File = undefined;
    var combined_out_file_buf: [OUT_FILE_BUF_SIZE]u8 = undefined;
    var combined_out_fw: std.Io.File.Writer = undefined;
    // Initialise to a Discarding writer up-front so a stray flush at
    // teardown is harmless even if no real combined sink was ever opened.
    // The `combined_file_opened` flag still gates the meaningful flush
    // path, but losing that invariant no longer reads undefined memory.
    var combined_discarding: std.Io.Writer.Discarding = .init(&combined_out_file_buf);
    var combined_fout: *std.Io.Writer = &combined_discarding.writer;
    var combined_json_first_row: bool = true;
    var combined_file_opened = false;
    defer if (combined_file_opened and !out.dry_run) combined_out_file.close(runtime.io);

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
        } else {
            // The combined roll-up is a whole-corpus artefact: it must
            // always reflect every input file. Under --fresh it is
            // therefore unconditionally (re)created from scratch — never
            // skip-if-exists — while the per-file loop below still honours
            // its own --fresh skip for individual per-file outputs. A
            // skipped per-file input is still iterated so its rows reach
            // the combined sink. (A plain truncating create matches the
            // non-fresh path; race protection on the combined sink is not
            // meaningful since its contents are deterministic from the
            // full input set.)
            combined_out_file = try dir.createFile(runtime.io, combined_out_name, .{});
            combined_file_opened = true;
            combined_out_fw = combined_out_file.writer(runtime.io, &combined_out_file_buf);
            combined_fout = &combined_out_fw.interface;
        }

        // Emit header once for the entire combined output.
        const delim_out_local = &[_]u8{bc.csv_delimiter_out};
        if (bc.file_type_out == .json) {
            try combined_fout.writeAll("[\n");
        } else {
            for (bc.output_schema.items, 0..) |col, ci| {
                if (ci > 0) try combined_fout.writeAll(delim_out_local);
                // Combined header is written once (outside the per-file arena),
                // so transcode into the GPA and free immediately per column.
                if (bc.csv_output_encoding == .utf8) {
                    try combined_fout.writeAll(col.header);
                } else {
                    const hdr = try encoding.encodeFromUtf8(alloc, col.header, bc.csv_output_encoding);
                    defer alloc.free(hdr);
                    try combined_fout.writeAll(hdr);
                }
            }
            try combined_fout.writeAll("\n");
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
        //
        // Date-filtered rows do NOT contribute: the `date_fast_path` opt (in
        // `evalAndEmitRow`) evaluates only `$date` and `return`s on an out-of-range row
        // before `evalAllVars` runs, so a broken non-`$date` expr on a row
        // that is excluded from the output never counts an error. This is
        // intentional — a row that produces no output line should not drag the
        // exit code to 2 — and is the one accounting difference from the
        // pre-optimization slow path (which evaluated every row's vars first
        // and dropped the row later). Output bytes stay byte-identical; only
        // the exit code on the broken-expr + filtered-out edge case differs.
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
        // FILENAME()/SHEET_NAME() per-file context. `stem` is the FILENAME()
        // value (same stem used for output naming + date extraction);
        // SHEET_NAME() is the configured xlsx sheet, "" for native CSV/JSON.
        const sheet_name_val: []const u8 = if (bc.xlsx_sheet) |xs| xs.name else "";
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
        var in_file = try dir.openFile(runtime.io, filename, .{});
        defer in_file.close(runtime.io);

        // Header structures persist across all chunks (live in file_alloc).
        var col_index = std.StringHashMap(usize).init(file_alloc);
        var col_names = std.array_list.Managed([]const u8).init(file_alloc);

        // Pre_pass results — populated in the streaming pre_pass below
        // (CSV) or the in-memory pre_pass over all_rows (JSON). Empty
        // when no pre_pass blocks are configured. Lives in file_alloc
        // so it survives both passes.
        var lookup_table = std.StringHashMap([]const u8).init(file_alloc);

        // JSON path streams records via `json_mod.RecordReader`. Two
        // separate passes happen below (Pass 0 = col_names discovery
        // here; Pass 1 = pre_pass; Pass 2 = main) — each pass rewinds
        // the file and re-instantiates a Reader, so we only carry a
        // boolean to tell the downstream branches which file format
        // they're consuming.
        var json_streaming = false;

        // CSV chunk reader — shared between pre_pass and main pass.
        // After pre_pass, the file is rewound and the reader is re-init'd
        // (since `ChunkReader` is owned by the file's read cursor and
        // can't seek backwards on its own).
        var chunk_reader: ChunkReader = undefined;
        var chunk_reader_inited = false;
        defer if (chunk_reader_inited) chunk_reader.deinit();

        // First chunk + body-start offset (after BOM + header). Captured
        // once during the initial header parse and re-captured after
        // rewind. The parallel block loop consumes records starting at
        // `first_chunk[first_chunk_body_start..]` from this chunk, then
        // pulls subsequent chunks via `chunk_reader.nextChunk()`.
        var first_chunk: []const u8 = "";
        var first_chunk_body_start: usize = 0;

        if (bc.file_type_in == .json) {
            // JSON Pass 0: stream the whole file once via `scanColNames`
            // to discover the union of object keys across all records
            // (first-seen order). No value materialisation, no slurp —
            // RSS bounded to the Scanner read buffer. Pre_pass / main
            // passes re-open the file below and instantiate their own
            // RecordReader.
            //
            // UTF-8 validation: dropped from the JSON path with the
            // streaming refactor. The std.json Scanner enforces UTF-8
            // inside string values (SyntaxError on invalid bytes);
            // structural characters (`{}[]:,`) and whitespace are
            // ASCII-only, so non-string UTF-8 garbage is rejected too.
            // The legacy whole-file `utf8ValidateSlice` warning is
            // therefore redundant.
            var pass0_buf: [json_mod.READ_BUF_SIZE]u8 = undefined;
            var pass0_freader = in_file.reader(runtime.io, &pass0_buf);
            try json_mod.scanColNames(file_alloc, &pass0_freader.interface, &col_names);
            for (col_names.items, 0..) |name, idx| try col_index.put(name, idx);
            json_streaming = true;
        } else {
            // CSV path: open the chunk reader, pull the first chunk,
            // validate UTF-8, parse the header (populates col_index +
            // col_names + dupe'd strings into file_alloc), and remember
            // where body records begin. The same `first_chunk` view is
            // reused both by the pre_pass block loop (when configured)
            // and by the main-pass block loop below.
            chunk_reader = try ChunkReader.init(runtime.io, file_alloc, in_file, CHUNK_SIZE);
            chunk_reader_inited = true;
            first_chunk = (try nextChunkChecked(&chunk_reader, out, filename)) orelse "";
            if (first_chunk.len > 0) {
                // First-chunk UTF-8 validation. Chunk boundaries always
                // land on '\n' (ASCII), so a multi-byte sequence is never
                // split across chunks; each chunk is independently
                // validatable. We validate only the first chunk to
                // approximate the legacy single-shot whole-file check
                // (cheap proxy for the common "BOM + Windows-1250 export"
                // failure mode). Skipped when csv_input_encoding declares a
                // legacy code page — there the bytes are *expected* to be
                // non-UTF-8 and are transcoded on access, so the warning
                // would be noise.
                if (bc.csv_input_encoding == .utf8 and !std.unicode.utf8ValidateSlice(first_chunk)) {
                    stats.warnings += 1;
                    out.warning("warning: '{s}' is not valid UTF-8; non-ASCII characters may be garbled\n", .{filename});
                }
                first_chunk_body_start = try parseCsvHeader(
                    first_chunk,
                    bc.csv_delimiter_in,
                    bc.csv_text_quote_in,
                    bc.csv_header_line,
                    bc.csv_input_encoding,
                    file_alloc,
                    &col_index,
                    &col_names,
                    out,
                    filename,
                    &stats,
                );
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

        // No-rows warning is now deferred for both formats — streaming
        // JSON discovers row count only during the main pass below
        // (mirrors the CSV chunk reader's deferral). See the warning
        // emission at file_end further down.

        const full_path = try std.Io.Dir.path.join(file_alloc, &.{ dir_path, filename });
        out.binEmitFileStart(
            if (json_streaming) .json else .csv,
            bid,
            full_path,
            col_names.items,
        );

        // Run pre_pass AFTER file_start so every prepass_entry frame /
        // prepass_set event is observed by a consumer that has already
        // seen the parent file_start. Otherwise a streaming GUI attributes
        // file N's prepass entries to file N-1 (whose file_end has fired
        // but whose currentFile slot is not yet cleared by file N's
        // file_start).
        if (bc.pre_passes.count() > 0) {
            if (json_streaming) {
                // JSON Pass 1 (parallel): re-open the file, stream records
                // serially from a Scanner-backed RecordReader into blocks
                // of `JSON_PARALLEL_BLOCK_SIZE` pre-parsed records, then
                // fork-join the worker pool over each block. Block arena
                // holds every record's fields while workers run; resets
                // after drain to bound RAM.
                const trace_on = out.btrace_writer != null or out.btrace_file_writer != null;
                for (workers) |*w| {
                    w.resetForFile();
                    w.setDebug(out.debug);
                    w.setBtraceEnabled(trace_on);
                }
                var prepass_buf: [json_mod.READ_BUF_SIZE]u8 = undefined;
                var prepass_freader = in_file.reader(runtime.io, &prepass_buf);
                var rr: json_mod.RecordReader = undefined;
                rr.init(file_alloc, &prepass_freader.interface, &col_index);
                defer rr.deinit();
                var block_arena = std.heap.ArenaAllocator.init(file_alloc);
                defer block_arena.deinit();
                var pending = std.array_list.Managed(ParsedJsonRecord).init(file_alloc);
                defer pending.deinit();
                try pending.ensureTotalCapacity(JSON_PARALLEL_BLOCK_SIZE);
                const rec_prepass = RowEvalConst{
                    .bc = bc,
                    .col_index = &col_index,
                    .col_names = col_names.items,
                    .lookup_table_ptr = null, // pre_pass has no self-reference
                    .single_prepass_name = null,
                    .date_min = date_min,
                    .date_max = date_max,
                    .bid = bid,
                    .filename = stem,
                    .sheet_name = sheet_name_val,
                };
                var pp_idx: u64 = 0; // cumulative records → RECORD_NUM() base
                while (true) {
                    const fields_opt = try rr.next(block_arena.allocator());
                    if (fields_opt) |fields| {
                        try pending.append(.{ .fields = fields, .byte_offset = rr.recordStartOffset() });
                        pp_idx += 1;
                    }
                    const flush_now = (fields_opt == null and pending.items.len > 0) or
                        pending.items.len >= JSON_PARALLEL_BLOCK_SIZE;
                    if (flush_now) {
                        const k_used = try processBlockParallelJson(pending.items, workers, runtime, &rec_prepass, true, pp_idx - pending.items.len);
                        try drainBlockPrePass(workers, k_used, out, &lookup_table);
                        pending.clearRetainingCapacity();
                        _ = block_arena.reset(.retain_capacity);
                    }
                    if (fields_opt == null) break;
                }
            } else if (chunk_reader_inited) {
                // CSV parallel pre_pass: workers populate per-worker
                // `partial_lookup` maps from per-chunk row slices; drain
                // merges them into the shared `lookup_table` in
                // worker-index order with last-writer-wins on duplicate
                // composite keys (matches the serial semantic where later
                // rows overwrite earlier rows for the same key).
                const trace_on = out.btrace_writer != null or out.btrace_file_writer != null;
                for (workers) |*w| {
                    w.resetForFile();
                    w.setDebug(out.debug);
                    w.setBtraceEnabled(trace_on);
                }
                var pending = std.array_list.Managed(csv.LineSlice).init(file_alloc);
                defer pending.deinit();
                var pp_idx: u64 = 0; // cumulative records → RECORD_NUM() base
                const rec_prepass = RowEvalConst{
                    .bc = bc,
                    .col_index = &col_index,
                    .col_names = col_names.items,
                    .lookup_table_ptr = null, // pre_pass has no self-reference
                    .single_prepass_name = null,
                    .date_min = date_min,
                    .date_max = date_max,
                    .bid = bid,
                    .filename = stem,
                    .sheet_name = sheet_name_val,
                };
                // First chunk: body lines starting after the header.
                if (first_chunk.len > first_chunk_body_start) {
                    var it = csv.LineIterator.init(
                        first_chunk[first_chunk_body_start..],
                        bc.csv_text_quote_in,
                        chunk_reader.chunk_start_in_file + first_chunk_body_start,
                    );
                    while (it.next()) |line| {
                        try pending.append(line);
                        pp_idx += 1;
                    }
                }
                if (pending.items.len > 0) {
                    const k_used = try processBlockParallel(pending.items, workers, runtime, &rec_prepass, true, pp_idx - pending.items.len);
                    try drainBlockPrePass(workers, k_used, out, &lookup_table);
                    pending.clearRetainingCapacity();
                }
                // Subsequent chunks (one block per chunk; ChunkReader
                // returns chunks already aligned on record boundaries
                // at ~10 MiB, which matches our target block size).
                while (try nextChunkChecked(&chunk_reader, out, filename)) |chunk_bytes| {
                    var it = csv.LineIterator.init(
                        chunk_bytes,
                        bc.csv_text_quote_in,
                        chunk_reader.chunk_start_in_file,
                    );
                    while (it.next()) |line| {
                        try pending.append(line);
                        pp_idx += 1;
                    }
                    if (pending.items.len > 0) {
                        const k_used = try processBlockParallel(pending.items, workers, runtime, &rec_prepass, true, pp_idx - pending.items.len);
                        try drainBlockPrePass(workers, k_used, out, &lookup_table);
                        pending.clearRetainingCapacity();
                    }
                }
                // Rewind file for main pass. A fresh `ChunkReader` reads
                // positionally from offset 0 (no OS file-cursor seek needed),
                // so we just deinit + re-init it. `skipBomAndHeader` skips the
                // same bytes that `parseCsvHeader` consumed during the
                // pre-pass header parse.
                chunk_reader.deinit();
                chunk_reader = try ChunkReader.init(runtime.io, file_alloc, in_file, CHUNK_SIZE);
                first_chunk = (try nextChunkChecked(&chunk_reader, out, filename)) orelse "";
                first_chunk_body_start = skipBomAndHeader(first_chunk, bc.csv_text_quote_in, bc.csv_header_line);
            }
        }

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
                dir.access(runtime.io, out_name, .{}) catch |e| {
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
        var out_file: std.Io.File = undefined;
        var out_file_buf: [OUT_FILE_BUF_SIZE]u8 = undefined;
        var out_fw: std.Io.File.Writer = undefined;
        var discarding: std.Io.Writer.Discarding = undefined;
        var per_file_opened = false;
        const fout: *std.Io.Writer = blk_sink: {
            if (out.dry_run) {
                discarding = .init(&out_file_buf);
                break :blk_sink &discarding.writer;
            }
            if (fresh) {
                if (dir.createFile(runtime.io, out_name, .{ .exclusive = true })) |f| {
                    out_file = f;
                } else |e| switch (e) {
                    error.PathAlreadyExists => {
                        // Per-file output already exists. When combined is
                        // enabled the combined sink always needs this file's
                        // rows (it is rebuilt in full every run), so keep
                        // iterating with a Discarding per-file writer so the
                        // combined gets filled — mirroring the "full run
                        // without --fresh" target state. Otherwise skip the
                        // whole iteration.
                        if (combined) {
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
                out_file = try dir.createFile(runtime.io, out_name, .{});
            }
            per_file_opened = true;
            out_fw = out_file.writer(runtime.io, &out_file_buf);
            break :blk_sink &out_fw.interface;
        };
        // A fatal raised anywhere below (e.g. `error.RecordTooLong` on a
        // newline-free input) must leave NO per-file output behind: `--fresh`
        // skips an input whose output merely exists, so a half-written or
        // 0-byte file would make the next `--fresh` run report success and
        // ship truncated data. `errdefer` fires only on an error leaving this
        // scope — a normal iteration end (or a `continue`) keeps the file.
        // Declared BEFORE the close `defer` on purpose: defers unwind in
        // reverse declaration order, so the handle is closed first and only
        // then is the name unlinked (Windows refuses to delete an open file).
        // The combined sink deliberately gets no such cleanup — it is
        // unconditionally rebuilt in full on every run (never `--fresh`
        // skipped), so a partial one cannot be mistaken for a complete one.
        errdefer if (per_file_opened) dir.deleteFile(runtime.io, out_name) catch {};
        defer if (per_file_opened) out_file.close(runtime.io);
        const delim_out = &[_]u8{bc.csv_delimiter_out};
        // Per-file header — always emitted at the start of the per-file
        // sink. Combined-mode header was written once above the loop.
        if (bc.file_type_out == .json) {
            try fout.writeAll("[\n");
        } else {
            for (bc.output_schema.items, 0..) |col, ci| {
                if (ci > 0) try fout.writeAll(delim_out);
                // Per-file header transcodes into the per-file arena (file_alloc),
                // reclaimed when the file's arena is torn down.
                const hdr = try encodeOutCell(file_alloc, col.header, bc.csv_output_encoding);
                try fout.writeAll(hdr);
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

        var json_first_row = true;
        // `file_rows_written` is u64 to match the `evalAndEmitRow` /
        // `binEmitOutputRow` signature shared with the parallel worker
        // path; both treat the counter as `*u64`. binEmitFileEnd consumes
        // it directly with no cast.
        var file_rows_written: u64 = 0;
        var file_row_idx: usize = 0;
        // Count of source records that ended with an unbalanced/stray quote
        // (treated as a literal byte — see `csv.LineIterator`). Surfaced as a
        // single per-file warning at file end so silent row loss can't recur.
        var file_unbalanced_quotes: u32 = 0;

        // Constant folding (Phase 3A): evaluate every row-invariant input_schema
        // expression ONCE here, before the parallel block fork, and reuse the
        // result for every row. Built on the main thread into file_alloc, then
        // shared read-only through `rec.folded_vars` to all workers. A fold is
        // taken only when (a) `expr.isRowInvariant` proves no field/lookup/
        // nondeterministic dependency AND (b) the expression evaluates without
        // error — an erroring constant stays dynamic so its per-row
        // `binEmitErrorRow` frames are preserved byte-identically.
        var folded_vars = std.StringHashMap([]const u8).init(file_alloc);
        {
            var fold_detail: []const u8 = "";
            var fold_ctx = expr_mod.Context{
                .fields = &.{},
                .col_index = &col_index,
                .quote_out = bc.csv_text_quote_out,
                .maps = &bc.maps,
                .lookup_table = null,
                .single_prepass_name = null,
                .alloc = file_alloc,
                .decimal_sep_in = bc.csv_decimal_separator_in,
                .input_encoding = bc.csv_input_encoding,
                .error_detail = &fold_detail,
            };
            var fold_it = bc.input_schema.iterator();
            while (fold_it.next()) |e| {
                if (!expr_mod.isRowInvariant(e.value_ptr.*, file_alloc)) continue;
                fold_detail = "";
                const v = expr_mod.evalString(e.value_ptr.*, &fold_ctx) catch continue;
                // Dupe into file_alloc: evalString may return a slice into the
                // config-owned src; duping pins the lifetime to this file's arena.
                try folded_vars.put(e.key_ptr.*, try file_alloc.dupe(u8, v));
            }
        }

        // opt 1: enable the early date-prefilter only when the filter is active,
        // `$date` is declared, and no row_rules override rewrites `$date` — so the
        // pre-override value the early check sees equals the post-override value
        // the late (in-override-loop) filter would otherwise compare against.
        const date_fast_path = blk: {
            if (date_min.len == 0 and date_max.len == 0) break :blk false;
            if (bc.input_schema.get(VAR_DATE) == null) break :blk false;
            const rules = bc.row_rules orelse break :blk true;
            for (rules) |rule| {
                for (rule.rows) |row_override| {
                    if (row_override.get(VAR_DATE) != null) break :blk false;
                }
            }
            break :blk true;
        };

        // opt 2: per-rule skip-sets — input_schema vars overwritten by EVERY
        // row of the rule (intersection across rule.rows). When the rule wins,
        // evalAllVars skips their base eval. Computed once per file into
        // file_alloc; indexed by row_rules position.
        var rule_skip_sets: []std.StringHashMap(void) = &.{};
        if (bc.row_rules) |rrules| {
            rule_skip_sets = try file_alloc.alloc(std.StringHashMap(void), rrules.len);
            for (rrules, 0..) |rule, ri| {
                var set = std.StringHashMap(void).init(file_alloc);
                if (rule.rows.len > 0) {
                    var it0 = rule.rows[0].iterator();
                    while (it0.next()) |ov| {
                        const k = ov.key_ptr.*;
                        if (bc.input_schema.get(k) == null) continue; // only input_schema vars
                        var in_all = true;
                        for (rule.rows[1..]) |orow| {
                            if (orow.get(k) == null) {
                                in_all = false;
                                break;
                            }
                        }
                        if (in_all) try set.put(k, {});
                    }
                }
                rule_skip_sets[ri] = set;
            }
        }

        // Phase 3B: precompile every input_schema expression once per file (the
        // file's col_index is now known). evalAllVars evaluates these nodes per
        // row instead of re-parsing the source string. Unsupported shapes fall
        // back to `.raw` (legacy fused eval) — byte-identical until later phases
        // lower more node kinds.
        const compiled_schema = try file_alloc.alloc(expr_mod.Node, bc.input_schema.count());
        for (bc.input_schema.values(), 0..) |src, i| {
            compiled_schema[i] = expr_mod.compile(src, &col_index, file_alloc);
        }

        // Phase 3B: precompile row_rules `when` + override values once per file,
        // aligned with each override map's iteration order so the per-row walk
        // can index into `compiled_rules` instead of re-lexing.
        var compiled_rules: ?[]const CompiledRule = null;
        if (bc.row_rules) |rrules| {
            const cr = try file_alloc.alloc(CompiledRule, rrules.len);
            for (rrules, 0..) |rule, ri| {
                const rows_nodes = try file_alloc.alloc([]const expr_mod.Node, rule.rows.len);
                for (rule.rows, 0..) |orow, rj| {
                    const ov = try file_alloc.alloc(expr_mod.Node, orow.count());
                    var it = orow.iterator();
                    var k: usize = 0;
                    while (it.next()) |entry| : (k += 1) {
                        ov[k] = expr_mod.compile(entry.value_ptr.*, &col_index, file_alloc);
                    }
                    rows_nodes[rj] = ov;
                }
                cr[ri] = .{ .when = expr_mod.compile(rule.when, &col_index, file_alloc), .rows = rows_nodes };
            }
            compiled_rules = cr;
        }

        // Const inputs shared between JSON serial loop and CSV parallel
        // workers. Both paths thread this through `evalAndEmitRow`; the
        // const view stays read-only inside workers.
        const rec = RowEvalConst{
            .bc = bc,
            .col_index = &col_index,
            .col_names = col_names.items,
            .lookup_table_ptr = lookup_table_ptr,
            .single_prepass_name = single_prepass_name,
            .date_min = date_min,
            .date_max = date_max,
            .bid = bid,
            .filename = stem,
            .sheet_name = sheet_name_val,
            .folded_vars = &folded_vars,
            .date_fast_path = date_fast_path,
            .rule_skip_sets = rule_skip_sets,
            .compiled_schema = compiled_schema,
            .compiled_rules = compiled_rules,
        };

        if (json_streaming) {
            // JSON Pass 2 (parallel): the serial Scanner reader fills a
            // block of pre-parsed `ParsedJsonRecord`, then `processBlock-
            // ParallelJson` fork-joins K = max_workers workers — each
            // evaluating its slice via `evalAndEmitRow`. `drainBlockMain`
            // writes per-worker output buffers in source-row order so the
            // output matches the single-threaded baseline byte-for-byte.
            const trace_on = out.btrace_writer != null or out.btrace_file_writer != null;
            for (workers) |*w| {
                w.setDebug(out.debug);
                w.setBtraceEnabled(trace_on);
            }
            var main_buf: [json_mod.READ_BUF_SIZE]u8 = undefined;
            var main_freader = in_file.reader(runtime.io, &main_buf);
            var rr: json_mod.RecordReader = undefined;
            rr.init(file_alloc, &main_freader.interface, &col_index);
            defer rr.deinit();
            var block_arena = std.heap.ArenaAllocator.init(file_alloc);
            defer block_arena.deinit();
            var pending = std.array_list.Managed(ParsedJsonRecord).init(file_alloc);
            defer pending.deinit();
            try pending.ensureTotalCapacity(JSON_PARALLEL_BLOCK_SIZE);
            while (true) {
                const fields_opt = try rr.next(block_arena.allocator());
                if (fields_opt) |fields| {
                    try pending.append(.{ .fields = fields, .byte_offset = rr.recordStartOffset() });
                    file_row_idx += 1;
                }
                const flush_now = (fields_opt == null and pending.items.len > 0) or
                    pending.items.len >= JSON_PARALLEL_BLOCK_SIZE;
                if (flush_now) {
                    const k_used = try processBlockParallelJson(pending.items, workers, runtime, &rec, false, @intCast(file_row_idx - pending.items.len));
                    try drainBlockMain(
                        workers,
                        k_used,
                        bc.file_type_out,
                        combined,
                        fout,
                        combined_fout,
                        &json_first_row,
                        &combined_json_first_row,
                        out,
                        &file_rows_written,
                        &file_expr_errors,
                    );
                    pending.clearRetainingCapacity();
                    _ = block_arena.reset(.retain_capacity);
                }
                if (fields_opt == null) break;
            }
        } else if (chunk_reader_inited) {
            // CSV parallel main loop. Per-chunk = per-block: collect
            // record slices from each chunk via LineIterator, fork K
            // workers via processBlockParallel, drain in worker-index
            // order via drainBlockMain. Workers don't reset their
            // `prepass_arena` here (resetForFile happened before the
            // pre_pass loop and the bytes feed the shared lookup_table).
            const trace_on = out.btrace_writer != null or out.btrace_file_writer != null;
            for (workers) |*w| {
                w.setDebug(out.debug);
                w.setBtraceEnabled(trace_on);
            }
            var pending = std.array_list.Managed(csv.LineSlice).init(file_alloc);
            defer pending.deinit();
            // First chunk: body lines starting after the header.
            if (first_chunk.len > first_chunk_body_start) {
                var it = csv.LineIterator.init(
                    first_chunk[first_chunk_body_start..],
                    bc.csv_text_quote_in,
                    chunk_reader.chunk_start_in_file + first_chunk_body_start,
                );
                while (it.next()) |line| {
                    if (line.unbalanced_quote) file_unbalanced_quotes += 1;
                    try pending.append(line);
                    file_row_idx += 1;
                }
            }
            if (pending.items.len > 0) {
                const k_used = try processBlockParallel(pending.items, workers, runtime, &rec, false, @intCast(file_row_idx - pending.items.len));
                try drainBlockMain(
                    workers,
                    k_used,
                    bc.file_type_out,
                    combined,
                    fout,
                    combined_fout,
                    &json_first_row,
                    &combined_json_first_row,
                    out,
                    &file_rows_written,
                    &file_expr_errors,
                );
                pending.clearRetainingCapacity();
            }
            // Subsequent chunks.
            while (try nextChunkChecked(&chunk_reader, out, filename)) |chunk_bytes| {
                var it = csv.LineIterator.init(
                    chunk_bytes,
                    bc.csv_text_quote_in,
                    chunk_reader.chunk_start_in_file,
                );
                while (it.next()) |line| {
                    if (line.unbalanced_quote) file_unbalanced_quotes += 1;
                    try pending.append(line);
                    file_row_idx += 1;
                }
                if (pending.items.len > 0) {
                    const k_used = try processBlockParallel(pending.items, workers, runtime, &rec, false, @intCast(file_row_idx - pending.items.len));
                    try drainBlockMain(
                        workers,
                        k_used,
                        bc.file_type_out,
                        combined,
                        fout,
                        combined_fout,
                        &json_first_row,
                        &combined_json_first_row,
                        out,
                        &file_rows_written,
                        &file_expr_errors,
                    );
                    pending.clearRetainingCapacity();
                }
            }
        }

        // Per-file tail + flush — always emitted at end-of-iteration.
        // Combined sink's tail/flush is deferred until after the loop
        // so every input file contributes to one closing array bracket.
        if (bc.file_type_out == .json) try fout.writeAll("\n]\n");
        try fout.flush();

        // No-rows warning: deferred from above for both formats because
        // streaming doesn't expose the count until the loop finishes.
        if (file_row_idx == 0) {
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

        // Unbalanced/stray quotes: each was treated as a literal byte so no
        // rows were lost (unlike the old RFC-4180 merge), but surface it once
        // per file — a stray quote usually means a malformed export.
        if (file_unbalanced_quotes > 0) {
            out.warning("warning: {d} row(s) in '{s}' had an unbalanced quote — treated as literal text (set csv_text_quote_in:\"none\" if the file is not quoted)\n", .{ file_unbalanced_quotes, filename });
            stats.warnings += 1;
            file_warnings += 1;
        }

        out.binEmitFileEnd(
            @intCast(file_row_idx),
            file_rows_written,
            file_expr_errors,
            file_warnings,
        );

        // Machine-readable run-summary accounting (--debug=json). Cheap, only
        // counters; the human summary path ignores these fields. Counted here
        // (not at loop top) so files skipped via --fresh `continue` above are
        // excluded — this branch runs once per file actually processed.
        stats.files += 1;
        stats.rows_in += @as(u64, file_row_idx);
        stats.rows_out += file_rows_written;
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

const XlsxErrAction = enum { skip_file, fatal };

/// Map an xlsx conversion error to a user-facing message + action, shared by
/// the serial workbook setup and the parallel sheet workers. A UTF-16 XML part
/// is recoverable (warn + skip the file); everything else is fatal. The caller
/// owns the fatal tail (`time_ns` + summary + `return error.Fatal`).
fn classifyXlsxErr(
    io: std.Io,
    err: anyerror,
    xlsx_name: []const u8,
    xlsx_file: std.Io.File,
    stats: *SectionStats,
    out: Output,
) XlsxErrAction {
    if (err == error.Utf16XmlUnsupported) {
        out.warning("warning: skipping '{s}': xlsx contains UTF-16 encoded XML, which is not supported — re-save the workbook from Excel as a normal .xlsx\n", .{xlsx_name});
        stats.warnings += 1;
        return .skip_file;
    }
    if (err == error.FileTooBig) {
        // The worksheet itself is streamed, so size is unbounded; the only
        // resident structure is the shared-strings table, capped defensively
        // against a zip-bomb (XLSX_SHARED_STRINGS_CAP).
        const on_disk: u64 = if (xlsx_file.stat(io)) |st| st.size else |_| 0;
        out.fatal("fatal error: xlsx '{s}' ({d} bytes on disk) has a shared-strings table exceeding the {d} MB safety limit (XLSX_SHARED_STRINGS_CAP)\n", .{ xlsx_name, on_disk, xlsx_mod.XLSX_SHARED_STRINGS_CAP / (1024 * 1024) });
        stats.has_fatal = true;
        return .fatal;
    }
    if (err == error.XlsxEntryCorrupt) {
        out.fatal(
            "fatal error: xlsx '{s}' is corrupt — a part's content does not match the CRC-32 the workbook declares\n",
            .{xlsx_name},
        );
    } else {
        out.fatal("fatal error: xlsx conversion failed for '{s}': {s}\n", .{ xlsx_name, @errorName(err) });
    }
    stats.has_fatal = true;
    return .fatal;
}

/// Shared state for the parallel per-sheet extraction of ONE xlsx file.
/// Mirrors `ZipUnpackCtx`: workers steal sheet indices off the `next` atomic
/// cursor (per-sheet sizes can be very uneven, so this load-balances) and
/// stash the first error; the main thread re-raises it after the barrier.
const XlsxFanCtx = struct {
    io: std.Io,
    dir: std.Io.Dir,
    xlsx_name: []const u8,
    wb: *const xlsx_mod.Workbook,
    specs: []const xlsx_mod.SheetSpec,
    stem: []const u8,
    alloc: std.mem.Allocator,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    // First-writer claim via CAS (Zig 0.16 removed `std.Thread.Mutex`; this
    // io-free guard suffices for the rare first-error record path).
    err_claimed: std.atomic.Value(bool) = .init(false),
    first_err: ?anyerror = null,

    fn record(self: *XlsxFanCtx, err: anyerror) void {
        if (self.err_claimed.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) {
            self.first_err = err;
        }
        self.failed.store(true, .monotonic);
    }
};

/// One parallel sheet-extraction worker. Opens its OWN file handle once (the
/// shared-cursor contract requires an independent archive per concurrent
/// reader, which `extractSheet` opens per sheet on this handle) and drains
/// sheet jobs off the shared cursor until the queue empties or another worker
/// fails. The `Workbook` is shared read-only.
///
/// Uses the pipeline's reclaiming allocator (`smp_allocator` in release, the
/// same one the serial path passes) — deliberately NOT a private arena:
/// `parseSheet` frees each row's cells as it advances to the next row, which
/// an arena turns into a no-op, accumulating every row's cells (~a whole
/// sheet's worth, ~10 MB on a 400k-row sheet) until the arena is reset.
fn xlsxExtractWorker(ctx: *XlsxFanCtx) void {
    const file = ctx.dir.openFile(ctx.io, ctx.xlsx_name, .{}) catch |err| return ctx.record(err);
    defer file.close(ctx.io);

    while (!ctx.failed.load(.monotonic)) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.specs.len) break;
        xlsx_mod.extractSheet(ctx.io, ctx.alloc, file, ctx.wb, ctx.specs[i], ctx.dir, ctx.stem) catch |err| return ctx.record(err);
    }
}

/// Converts xlsx files to intermediate CSV before the main processing loop.
///
/// Groups SheetSpecs by data_dir so each xlsx file is extracted only once,
/// even when multiple templates share the same directory. Within a file the
/// sheets are extracted in parallel (fan-out via `std.Io.Group.async` over
/// `runtime.io`, mirroring `zipPrePass`); the shared workbook parts are parsed
/// once up front.
/// Prints its own section header and summary when any xlsx files were found.
/// Returns accumulated SectionStats for this pre-pass.
pub fn xlsxPrePass(
    cfg: *const config_mod.Config,
    alloc: std.mem.Allocator,
    out: Output,
    fresh: bool,
    template_id: ?[]const u8,
    dir_path_arg: ?[]const u8,
    runtime: Runtime,
) !SectionStats {
    var xlsx_stats = SectionStats{};
    var timer = Timer.begin(runtime.io);

    var dir_specs: std.StringArrayHashMapUnmanaged(std.array_list.Managed(xlsx_mod.SheetSpec)) = .empty;
    defer {
        var ds_it = dir_specs.iterator();
        while (ds_it.next()) |e| e.value_ptr.deinit();
        dir_specs.deinit(alloc);
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

        const gop = try dir_specs.getOrPut(alloc, dir_path);
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

        var dir = std.Io.Dir.cwd().openDir(runtime.io, dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                out.fatal("error: directory not found: '{s}'\n", .{dir_path});
                xlsx_stats.has_fatal = true;
                continue;
            }
            return err;
        };
        defer dir.close(runtime.io);

        var xlsx_names = std.array_list.Managed([]u8).init(alloc);
        defer {
            for (xlsx_names.items) |n| alloc.free(n);
            xlsx_names.deinit();
        }
        {
            var fit = dir.iterate();
            while (try fit.next(runtime.io)) |entry| {
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
                    dir.access(runtime.io, csvx_name, .{}) catch {
                        all_exist = false;
                        break;
                    };
                }
                if (all_exist) {
                    out.info("  skipping '{s}' (output exists)\n", .{xlsx_name});
                    continue;
                }
            }

            const xlsx_file = try dir.openFile(runtime.io, xlsx_name, .{});
            defer xlsx_file.close(runtime.io);

            out.info("converting '{s}'\n", .{xlsx_name});

            // Shared setup (serial): parse the workbook-global parts once
            // (sheet name→path map, shared-strings table, date styles).
            var wb = xlsx_mod.Workbook.init(runtime.io, alloc, xlsx_file) catch |err| {
                switch (classifyXlsxErr(runtime.io, err, xlsx_name, xlsx_file, &xlsx_stats, out)) {
                    .skip_file => continue,
                    .fatal => {
                        xlsx_stats.time_ns = timer.read();
                        out.summary(xlsx_stats);
                        return error.Fatal;
                    },
                }
            };
            defer wb.deinit(alloc);

            // Execution (parallel): fan the per-sheet extraction out across
            // workers. The sheets are independent XML members of the one
            // archive, so this load-balances across cores the same way
            // zipPrePass unpacks independent zip members — the serial sheet
            // loop was the xlsx ingest cap.
            if (specs.len > 0) {
                var fan = XlsxFanCtx{
                    .io = runtime.io,
                    .dir = dir,
                    .xlsx_name = xlsx_name,
                    .wb = &wb,
                    .specs = specs,
                    .stem = stem,
                    .alloc = alloc,
                };
                const k = @min(runtime.max_workers, specs.len);
                var g: std.Io.Group = .init;
                for (0..k) |_| g.async(runtime.io, xlsxExtractWorker, .{&fan});
                g.await(runtime.io) catch {};
                if (fan.first_err) |err| {
                    switch (classifyXlsxErr(runtime.io, err, xlsx_name, xlsx_file, &xlsx_stats, out)) {
                        .skip_file => continue,
                        .fatal => {
                            xlsx_stats.time_ns = timer.read();
                            out.summary(xlsx_stats);
                            return error.Fatal;
                        },
                    }
                }
            }
        }
    }

    xlsx_stats.time_ns = timer.read();
    out.summary(xlsx_stats);
    return xlsx_stats;
}

/// Derives the flat intermediate-CSV filename for one zip member, per the
/// template's `zip_input.dir_mode`. The member name has already had '\' → '/'
/// normalised by zipstream, so `basename` splits on '/' on every host.
/// Allocated from `alloc`.
fn zipEntryOutputName(alloc: std.mem.Allocator, entry_name: []const u8, zi: config_mod.ZipInput) ![]u8 {
    return switch (zi.dir_mode) {
        .basename => try alloc.dupe(u8, std.Io.Dir.path.basename(entry_name)),
        .keep_path => try std.mem.replaceOwned(u8, alloc, entry_name, "/", zi.path_separator),
    };
}

/// One unpack job produced by the serial planning phase: which archive member
/// to inflate, and the validated flat output filename it writes to. Names are
/// pre-derived + zip-slip/collision-checked serially, so workers share no
/// mutable naming state — they only inflate + write independent files.
const ZipJob = struct {
    entry_idx: usize,
    out_name: []const u8,
};

/// Shared state for the parallel unpack of ONE zip. Workers steal jobs off the
/// `next` atomic cursor (so the wildly uneven per-member sizes load-balance
/// automatically) and stash the first error they hit; the main thread
/// re-raises it after the `std.Io.Group.await` barrier — workers can't propagate
/// errors out through `Io.Group.async`, the same constraint the main pipeline's
/// blocks have.
const ZipUnpackCtx = struct {
    io: std.Io,
    dir: std.Io.Dir,
    zip_name: []const u8,
    jobs: []const ZipJob,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    // First-writer claim via CAS (Zig 0.16 removed `std.Thread.Mutex`).
    err_claimed: std.atomic.Value(bool) = .init(false),
    first_err: ?anyerror = null,
    first_err_name: []const u8 = "",

    fn record(self: *ZipUnpackCtx, err: anyerror, name: []const u8) void {
        if (self.err_claimed.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) {
            self.first_err = err;
            self.first_err_name = name;
        }
        self.failed.store(true, .monotonic);
    }
};

/// Inflate one archive member to a flat file in `dir`. Pure per-entry work with
/// no shared state — the parallel unpack worker calls this once per job.
fn unpackOneEntry(
    io: std.Io,
    archive: *zipstream.Archive,
    member: *const zipstream.Entry,
    out_name: []const u8,
    dir: std.Io.Dir,
    window: []u8,
    wbuf: []u8,
) !void {
    var er: zipstream.EntryReader = undefined;
    // `initMax` rather than `init`: the upstream default caps one entry's
    // decompressed output at 1 GiB. A zipped broker/dataset CSV can legitimately
    // exceed that, and the unpack streams straight to disk through one inflate
    // window, so the cap would reject valid input without protecting anything
    // this pass owns. Passing the maximum keeps the pre-migration contract.
    try er.initMax(archive, member, window, std.math.maxInt(u64));
    const dest = try dir.createFile(io, out_name, .{});
    // A failed member must leave NO file behind. `--fresh` skips a member
    // whose intermediate CSV merely exists (see `zipPrePass`), and a CRC-32
    // mismatch is only detectable at end-of-stream — by which point the
    // (truncated, unflushed) bytes are already on disk. Without this cleanup
    // the next `--fresh` run reports "unpacked (0 members)" with exit 0 and
    // converts the partial file as if it were complete.
    // Declared BEFORE the close `defer` on purpose: defers unwind in reverse
    // declaration order, so the handle is closed first and only then is the
    // name unlinked (Windows refuses to delete a file that is still open).
    // The xlsx pre-pass does not need the same guard on its `--fresh` side —
    // it keys on the FINAL `.csvx`, not on the intermediate CSV — but
    // `xlsx.extractSheetWithCtx` carries its own `errdefer` for the same
    // reason: a leftover intermediate is converted by the very same run.
    errdefer dir.deleteFile(io, out_name) catch {};
    defer dest.close(io);
    var fw = dest.writer(io, wbuf);
    _ = er.reader().streamRemaining(&fw.interface) catch |err| {
        // `std.Io.Reader`'s vtable has a fixed error set, so a CRC-32 mismatch
        // at end-of-stream can only surface as the generic `ReadFailed`.
        // `crcMismatch()` is zipstream's out-of-band way to tell "this member's
        // bytes do not match the checksum the archive itself declares" apart
        // from an ordinary I/O failure — worth distinguishing, because the two
        // ask the user for completely different things (re-download a
        // corrupted archive vs. check the disk).
        if (er.crcMismatch()) return error.ZipEntryCorrupt;
        return err;
    };
    try fw.interface.flush();
}

/// One parallel unpack worker. Opens its OWN file handle and walks the central
/// directory into its OWN `Archive` — that gives it an independent file cursor,
/// which the shared-cursor contract requires (concurrent `EntryReader`s on one
/// `Archive` would race the single cursor). The walk is ~1 ms and deterministic,
/// so `entry_idx` from the planner indexes this archive's entries identically.
/// Drains jobs until the queue empties or another worker has failed.
fn zipUnpackWorker(ctx: *ZipUnpackCtx) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const wa = arena.allocator();

    const file = ctx.dir.openFile(ctx.io, ctx.zip_name, .{}) catch |err| return ctx.record(err, ctx.zip_name);
    defer file.close(ctx.io);

    var archive: zipstream.Archive = undefined;
    archive.init(ctx.io, wa, file) catch |err| return ctx.record(err, ctx.zip_name);
    defer archive.deinit();

    const window = wa.alloc(u8, std.compress.flate.max_window_len) catch |err| return ctx.record(err, ctx.zip_name);
    var wbuf: [OUT_FILE_BUF_SIZE]u8 = undefined;

    while (!ctx.failed.load(.monotonic)) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.jobs.len) break;
        const job = ctx.jobs[i];
        unpackOneEntry(ctx.io, &archive, &archive.entries.items[job.entry_idx], job.out_name, ctx.dir, window, &wbuf) catch |err| {
            ctx.record(err, job.out_name);
            return;
        };
    }
}

/// Unpacks each *.zip in a template's data_dir into flat intermediate CSV
/// files before the main processing loop. Mirrors `xlsxPrePass`: groups by
/// data_dir so a shared directory is unpacked once, streams every member
/// whose in-zip name ends with `zip_input.entry_pattern` out of the archive
/// (memory bounded to one inflate window via the `zipstream` primitive), and
/// names each output per `zip_input.dir_mode`. N members → N CSVs, not 1:1.
///
/// Output names are always flat (no path separator), so a member can never
/// escape data_dir (zip-slip); a member mapping to a separator, "."/"..", or
/// a name already produced by another member is a fatal error rather than a
/// silent clobber. Prints its own section header + summary when any zip work
/// was found.
pub fn zipPrePass(
    cfg: *const config_mod.Config,
    alloc: std.mem.Allocator,
    out: Output,
    fresh: bool,
    template_id: ?[]const u8,
    dir_path_arg: ?[]const u8,
    runtime: Runtime,
) !SectionStats {
    var stats = SectionStats{};
    var timer = Timer.begin(runtime.io);

    // data_dir -> ZipInput (first active template wins; a shared dir is
    // unpacked once). Mirrors xlsxPrePass's per-dir dedupe.
    var dir_specs: std.StringArrayHashMapUnmanaged(config_mod.ZipInput) = .empty;
    defer dir_specs.deinit(alloc);

    var bc_it = cfg.brokers.iterator();
    while (bc_it.next()) |entry| {
        const bc = entry.value_ptr;
        const zi = bc.zip_input orelse continue;
        const dir_path: []const u8 = if (template_id) |tid| blk: {
            if (!std.mem.eql(u8, tid, entry.key_ptr.*)) continue;
            break :blk dir_path_arg orelse bc.data_dir;
        } else bc.data_dir;
        const gop = try dir_specs.getOrPut(alloc, dir_path);
        if (!gop.found_existing) gop.value_ptr.* = zi;
    }

    if (dir_specs.count() == 0) return stats;

    out.info("\n=== unpacking zip archives ===\n", .{});

    var ds_it = dir_specs.iterator();
    while (ds_it.next()) |e| {
        const dir_path = e.key_ptr.*;
        const zi = e.value_ptr.*;

        var dir = std.Io.Dir.cwd().openDir(runtime.io, dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                out.fatal("error: directory not found: '{s}'\n", .{dir_path});
                stats.has_fatal = true;
                continue;
            }
            return err;
        };
        defer dir.close(runtime.io);

        // Collect + sort the *.zip files so extraction order is deterministic.
        var zip_names = std.array_list.Managed([]u8).init(alloc);
        defer {
            for (zip_names.items) |n| alloc.free(n);
            zip_names.deinit();
        }
        {
            var fit = dir.iterate();
            while (try fit.next(runtime.io)) |de| {
                if (de.kind != .file and de.kind != .sym_link) continue;
                if (!std.mem.endsWith(u8, de.name, ".zip")) continue;
                try zip_names.append(try alloc.dupe(u8, de.name));
            }
        }
        std.mem.sort([]u8, zip_names.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (zip_names.items) |zip_name| {
            const zip_file = dir.openFile(runtime.io, zip_name, .{}) catch |err| {
                out.fatal("fatal error: cannot open zip '{s}': {s}\n", .{ zip_name, @errorName(err) });
                stats.has_fatal = true;
                stats.time_ns = timer.read();
                out.summary(stats);
                return error.Fatal;
            };
            defer zip_file.close(runtime.io);

            var archive: zipstream.Archive = undefined;
            archive.init(runtime.io, alloc, zip_file) catch |err| {
                if (err == zipstream.Error.UnsupportedCompressionMethod) {
                    out.warning("warning: skipping '{s}': uses an unsupported compression method (only store + deflate are read)\n", .{zip_name});
                    stats.warnings += 1;
                    continue;
                }
                out.fatal("fatal error: cannot read zip '{s}': {s}\n", .{ zip_name, @errorName(err) });
                stats.has_fatal = true;
                stats.time_ns = timer.read();
                out.summary(stats);
                return error.Fatal;
            };
            defer archive.deinit();

            // Per-zip arena: derived output names + the collision set + the
            // job list. Freed when this archive is done — i.e. after the
            // parallel unpack below joins (workers read job.out_name).
            var name_arena = std.heap.ArenaAllocator.init(alloc);
            defer name_arena.deinit();
            const na = name_arena.allocator();
            var seen = std.StringHashMap(void).init(na);

            // Planning phase (serial): derive + validate every output name and
            // collect the unpack jobs. Naming, the zip-slip guard and collision
            // detection need the global view, so they stay single-threaded;
            // only the independent inflate + file writes are parallelised.
            var jobs = std.array_list.Managed(ZipJob).init(na);
            for (archive.entries.items, 0..) |*member, idx| {
                if (!std.mem.endsWith(u8, member.name, zi.entry_pattern)) continue;

                const out_name = try zipEntryOutputName(na, member.name, zi);
                // Zip-slip / sanity guard: a flat name only — never a path
                // separator (so it can't escape data_dir), never empty/"."/"..".
                if (out_name.len == 0 or
                    std.mem.indexOfScalar(u8, out_name, '/') != null or
                    std.mem.eql(u8, out_name, ".") or std.mem.eql(u8, out_name, ".."))
                {
                    out.fatal("fatal error: zip '{s}': member '{s}' maps to an unsafe output name '{s}'\n", .{ zip_name, member.name, out_name });
                    stats.has_fatal = true;
                    stats.time_ns = timer.read();
                    out.summary(stats);
                    return error.Fatal;
                }
                // Collision guard: two members must not target the same file.
                if (seen.contains(out_name)) {
                    out.fatal("fatal error: zip '{s}': two members map to the same output file '{s}' — set zip_input.dir_mode to \"keep_path\"\n", .{ zip_name, out_name });
                    stats.has_fatal = true;
                    stats.time_ns = timer.read();
                    out.summary(stats);
                    return error.Fatal;
                }
                try seen.put(out_name, {});

                // --fresh: skip members whose intermediate CSV already exists.
                if (fresh) {
                    if (dir.access(runtime.io, out_name, .{})) |_| {
                        continue;
                    } else |_| {}
                }
                try jobs.append(.{ .entry_idx = idx, .out_name = out_name });
            }

            // Execution phase: inflate + write the jobs in parallel. The N
            // members are independent (validated flat names, distinct files), so
            // this is embarrassingly parallel — workers steal jobs off a shared
            // atomic cursor (load-balances the very uneven per-member sizes),
            // each driving its own file cursor + inflate window. `unzip` is
            // single-threaded, so this is where we pull ahead of it.
            if (jobs.items.len > 0) {
                const k = @min(runtime.max_workers, jobs.items.len);
                var ctx = ZipUnpackCtx{
                    .io = runtime.io,
                    .dir = dir,
                    .zip_name = zip_name,
                    .jobs = jobs.items,
                };
                var g: std.Io.Group = .init;
                for (0..k) |_| g.async(runtime.io, zipUnpackWorker, .{&ctx});
                g.await(runtime.io) catch {};
                if (ctx.first_err) |err| {
                    if (err == error.ZipEntryCorrupt) {
                        out.fatal(
                            "fatal error: zip '{s}': member '{s}' is corrupt — its content does not match the CRC-32 the archive declares\n",
                            .{ zip_name, ctx.first_err_name },
                        );
                    } else {
                        out.fatal("fatal error: zip '{s}': failed unpacking '{s}': {s}\n", .{ zip_name, ctx.first_err_name, @errorName(err) });
                    }
                    stats.has_fatal = true;
                    stats.time_ns = timer.read();
                    out.summary(stats);
                    return error.Fatal;
                }
            }
            out.info("  unpacked '{s}' ({d} members)\n", .{ zip_name, jobs.items.len });
        }
    }

    stats.time_ns = timer.read();
    out.summary(stats);
    return stats;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Run `writeSafeValue` with default CSV punctuation (`,` delimiter, `.`
/// decimal, `"` quote) and assert the written bytes equal `expected`.
fn expectSafeValue(value: []const u8, expected: []const u8) !void {
    var out_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    var val_buf: [VAL_BUF_SIZE]u8 = undefined;
    try writeSafeValue(&w, value, ',', '.', '"', &val_buf);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "writeSafeValue: formula-injection leads get an apostrophe guard" {
    // OWASP CSV-injection set: '=', '+', '@', tab, and CR all open a formula
    // in Excel/LibreOffice; prefix with ' so the cell renders as literal text.
    try expectSafeValue("=cmd|'/c calc'!A1", "'=cmd|'/c calc'!A1");
    try expectSafeValue("@SUM(A1:A9)", "'@SUM(A1:A9)");
    try expectSafeValue("+cmd|'/c calc'!A1", "'+cmd|'/c calc'!A1");
    try expectSafeValue("\t=1+1", "'\t=1+1");
    // A digit after the sign is not an escape hatch: the DDE link decides.
    try expectSafeValue("-1+cmd|'/c calc'!A1", "'-1+cmd|'/c calc'!A1");
}

test "writeSafeValue: the guard also runs on the quoted paths" {
    // A spreadsheet strips CSV quoting before parsing the cell, so a value
    // that needs RFC 4180 quoting still needs the guard — inside the quotes.
    try expectSafeValue("@SUM(1,1)", "\"'@SUM(1,1)\"");
    try expectSafeValue(
        "=HYPERLINK(\"http://evil.example\",\"click\")",
        "\"'=HYPERLINK(\"\"http://evil.example\"\",\"\"click\"\")\"",
    );
    // Pre-quoted pass-through (a ''' expression): guard goes inside too.
    try expectSafeValue("\"=1+2\"", "\"'=1+2\"");
}

test "writeSafeValue: signed numbers are not mangled by the guard" {
    // '+' and '-' legitimately lead a number; prefixing would make the
    // portfolio tracker parse them as strings.
    try expectSafeValue("-12.34", "-12.34");
    try expectSafeValue("+5", "+5");
    try expectSafeValue("+.5", "+.5");
    try expectSafeValue("-.5", "-.5");
    try expectSafeValue("+420 555 0101", "+420 555 0101"); // intl phone number
}

test "writeSafeValue: text after a sign or @ is data, not a formula" {
    // Every one of these is a real value from the corpus scan (Chicago
    // business register, IMDb titles, Airbnb listings, a Schwab export).
    // None can execute — a spreadsheet shows them as text or #NAME? — so an
    // apostrophe here would only corrupt the value for every consumer.
    try expectSafeValue("-ISM FURNITURE, LLC", "\"-ISM FURNITURE, LLC\"");
    try expectSafeValue("@ 35, INC.", "\"@ 35, INC.\"");
    try expectSafeValue("@midnight with Doug Benson and more!", "@midnight with Doug Benson and more!");
    try expectSafeValue("@HouseOnHenrySt Private 1 bedroom", "@HouseOnHenrySt Private 1 bedroom");
    try expectSafeValue("-$1,259.59", "\"-$1,259.59\"");
    try expectSafeValue("-- comment", "-- comment");
    try expectSafeValue("+", "+"); // lone sign: no machinery, no formula
    try expectSafeValue("-", "-");
}

// ── Pure helpers exercised end-to-end by the dataset gate, but with no
//    edge-case coverage of their own. These pin the boundary behaviour a
//    structural refactor could silently regress without a dataset noticing
//    (e.g. a filename date-range shape no fixture uses). ─────────────────

test "extractDateRange: valid, embedded, none, too-short" {
    // Bare range at the start of the stem.
    switch (extractDateRange("2026-01-01_2026-03-31")) {
        .valid => |r| {
            try std.testing.expectEqualStrings("2026-01-01", r.min);
            try std.testing.expectEqualStrings("2026-03-31", r.max);
        },
        else => return error.TestUnexpectedResult,
    }
    // Range embedded between a prefix and suffix.
    switch (extractDateRange("CZK_2025-12-01_2025-12-31_cash")) {
        .valid => |r| {
            try std.testing.expectEqualStrings("2025-12-01", r.min);
            try std.testing.expectEqualStrings("2025-12-31", r.max);
        },
        else => return error.TestUnexpectedResult,
    }
    // No range present.
    try std.testing.expect(extractDateRange("statement_q1") == .none);
    // Shorter than the 21-char pattern can't match.
    try std.testing.expect(extractDateRange("2026-01-01") == .none);
}

test "extractDateRange: min>max and bad components are .invalid (not silent .none)" {
    // Well-formed shape but min later than max — a typo'd range, flagged so
    // the row filter doesn't silently drop every row.
    try std.testing.expect(extractDateRange("2026-03-31_2026-01-01") == .invalid);
    // Right shape, impossible components (month 13, day 99).
    try std.testing.expect(extractDateRange("2026-13-01_2026-99-31") == .invalid);
}

// `findLastBoundary` and its test went upstream with the reader — it is now
// private to the `csvstream` module, which tests it through `ChunkReader`
// directly (plus a fuzz harness and the csv-spectrum corpus). The
// `ChunkReader` test further down stays: it is the integration check that this
// file drives the module the way its offset bookkeeping expects.

test "skipBomAndHeader: BOM, no BOM, headerless, multi-line preamble" {
    const q = '"';
    // No BOM, single header line skipped → body starts after "h1,h2\n".
    try std.testing.expectEqual(@as(usize, 6), skipBomAndHeader("h1,h2\nv1,v2\n", q, 1));
    // Leading UTF-8 BOM (3 bytes) + one header line.
    try std.testing.expectEqual(@as(usize, 9), skipBomAndHeader("\xEF\xBB\xBFh1,h2\nv1,v2\n", q, 1));
    // Headerless (header_line == 0): only the BOM is skipped, first line is data.
    try std.testing.expectEqual(@as(usize, 0), skipBomAndHeader("v1,v2\n", q, 0));
    try std.testing.expectEqual(@as(usize, 3), skipBomAndHeader("\xEF\xBB\xBFv1,v2\n", q, 0));
    // Preamble: header on line 3 → skip 3 lines total ("pre1\n"+"pre2\n"+"h1,h2\n").
    try std.testing.expectEqual(@as(usize, 16), skipBomAndHeader("pre1\npre2\nh1,h2\nv1,v2\n", q, 3));
    // Header beyond the chunk → clamps to chunk length (caller treats as no body).
    try std.testing.expectEqual(@as(usize, 6), skipBomAndHeader("h1,h2\n", q, 5));
}

test "parseCsvHeader: duplicate names warn once, last-wins, empties silent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fa = arena.allocator();

    // Capture warnings via json_debug's msg_sink so nothing hits stderr. The
    // captured strings are arena-owned (`captureMsg` stores a trimmed sub-slice
    // of its allocation, so they can't be individually freed by their pointer).
    var sink = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer sink.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const out = Output{
        .writer = &aw.writer,
        .quiet = false,
        .debug = false,
        .json_debug = true,
        .msg_sink = &sink,
        .msg_alloc = fa,
    };

    var col_index = std.StringHashMap(usize).init(std.testing.allocator);
    defer col_index.deinit();
    var col_names = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer col_names.deinit();
    var stats = SectionStats{};

    // "amount" appears 3× (1-based columns 2, 4, 6) → one warning; two trailing
    // empty headers (columns 7, 8) repeat but must stay silent.
    const chunk = "id,amount,fee,amount,note,amount,,\nx,1,2,3,4,5,6,7\n";
    _ = try parseCsvHeader(chunk, ',', '"', 1, .utf8, fa, &col_index, &col_names, out, "dup.csv", &stats);

    // Exactly one warning for the one repeated non-empty name, naming every
    // 1-based column and which one `[amount]` reads.
    try std.testing.expectEqual(@as(u32, 1), stats.warnings);
    try std.testing.expectEqual(@as(usize, 1), sink.items.len);
    try std.testing.expect(std.mem.indexOf(u8, sink.items[0], "duplicate column header 'amount' at columns 2, 4, 6") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.items[0], "[amount] reads column 6") != null);

    // Last-wins: [amount] resolves to its rightmost column (index 5 = column 6).
    try std.testing.expectEqual(@as(usize, 5), col_index.get("amount").?);
    // Non-repeated names keep their position.
    try std.testing.expectEqual(@as(usize, 2), col_index.get("fee").?);
}

test "ChunkReader: residual + chunk_start_in_file bookkeeping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "a,1\nb,2\nc,3\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in.csv", .data = body });
    var f = try tmp.dir.openFile(std.testing.io, "in.csv", .{});
    defer f.close(std.testing.io);
    var cr = try ChunkReader.init(std.testing.io, std.testing.allocator, f, CHUNK_SIZE);
    defer cr.deinit();
    // File is far below CHUNK_SIZE, so the whole body comes back as one chunk
    // ending on its final '\n'; offset starts at 0.
    const c0 = (try cr.nextChunk()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(body, c0);
    try std.testing.expectEqual(@as(u64, 0), cr.chunk_start_in_file);
    // Nothing left after the trailing newline.
    try std.testing.expect((try cr.nextChunk()) == null);
}

test "patchBtraceOutputIdx: rebases output_row idx, leaves other frames" {
    // Hand-build one output_row frame per the documented layout:
    //   [1B type=0x03][2B chunk_id][4B pay_len]
    //   [8B source_locator][8B output_idx][4B rule_idx][4B action_len][N action]
    var buf: [64]u8 = undefined;
    const action = "BUY";
    const pay_len: u32 = 8 + 8 + 4 + 4 + @as(u32, action.len);
    buf[0] = @intFromEnum(btrace.FrameType.output_row);
    std.mem.writeInt(u16, buf[1..3], 0, .little); // chunk_id
    std.mem.writeInt(u32, buf[3..7], pay_len, .little);
    std.mem.writeInt(u64, buf[7..15], 42, .little); // source_locator
    std.mem.writeInt(u64, buf[15..23], 5, .little); // output_idx (pre-patch)
    std.mem.writeInt(u32, buf[23..27], 1, .little); // rule_idx
    std.mem.writeInt(u32, buf[27..31], action.len, .little);
    @memcpy(buf[31 .. 31 + action.len], action);
    const frame_len = 7 + pay_len;

    patchBtraceOutputIdx(buf[0..frame_len], 100);
    try std.testing.expectEqual(@as(u64, 105), std.mem.readInt(u64, buf[15..23], .little));

    // A non-output frame at the same offset must be left untouched.
    buf[0] = @intFromEnum(btrace.FrameType.file_end);
    std.mem.writeInt(u64, buf[15..23], 5, .little);
    patchBtraceOutputIdx(buf[0..frame_len], 100);
    try std.testing.expectEqual(@as(u64, 5), std.mem.readInt(u64, buf[15..23], .little));
}

/// Build a one-member, store-only ZIP by hand, with the member's CRC-32 field
/// set to `crc`. Passing a wrong `crc` is how the test below reaches the
/// end-of-stream checksum failure — the only failure mode that can leave a
/// partially written output file behind.
fn buildStoreZip(alloc: std.mem.Allocator, name: []const u8, data: []const u8, crc: u32) ![]u8 {
    var z: std.Io.Writer.Allocating = .init(alloc);
    errdefer z.deinit();
    const w = &z.writer;

    // ── Local file header (30 bytes + name) ──
    try w.writeAll("PK\x03\x04");
    try w.writeInt(u16, 20, .little); // version needed
    try w.writeInt(u16, 0, .little); // flags
    try w.writeInt(u16, 0, .little); // method: store
    try w.writeInt(u16, 0, .little); // mod time
    try w.writeInt(u16, 0, .little); // mod date
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, @intCast(data.len), .little); // compressed size
    try w.writeInt(u32, @intCast(data.len), .little); // uncompressed size
    try w.writeInt(u16, @intCast(name.len), .little);
    try w.writeInt(u16, 0, .little); // extra len
    try w.writeAll(name);
    try w.writeAll(data);

    // ── Central directory (46 bytes + name) ──
    const cd_off = z.written().len;
    try w.writeAll("PK\x01\x02");
    try w.writeInt(u16, 20, .little); // version made by
    try w.writeInt(u16, 20, .little); // version needed
    try w.writeInt(u16, 0, .little); // flags
    try w.writeInt(u16, 0, .little); // method: store
    try w.writeInt(u16, 0, .little); // mod time
    try w.writeInt(u16, 0, .little); // mod date
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, @intCast(data.len), .little);
    try w.writeInt(u32, @intCast(data.len), .little);
    try w.writeInt(u16, @intCast(name.len), .little);
    try w.writeInt(u16, 0, .little); // extra len
    try w.writeInt(u16, 0, .little); // comment len
    try w.writeInt(u16, 0, .little); // disk number start
    try w.writeInt(u16, 0, .little); // internal attrs
    try w.writeInt(u32, 0, .little); // external attrs
    try w.writeInt(u32, 0, .little); // local header offset
    try w.writeAll(name);
    const cd_len = z.written().len - cd_off;

    // ── End of central directory (22 bytes) ──
    try w.writeAll("PK\x05\x06");
    try w.writeInt(u16, 0, .little); // this disk
    try w.writeInt(u16, 0, .little); // cd start disk
    try w.writeInt(u16, 1, .little); // entries on this disk
    try w.writeInt(u16, 1, .little); // entries total
    try w.writeInt(u32, @intCast(cd_len), .little);
    try w.writeInt(u32, @intCast(cd_off), .little);
    try w.writeInt(u16, 0, .little); // comment len

    return z.toOwnedSlice();
}

test "unpackOneEntry: a CRC-mismatched member leaves no partial output behind" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Content is intact; only the declared CRC-32 is wrong, so the failure
    // lands at end-of-stream — after every byte has been handed to the writer.
    // That is exactly the case that used to leave a truncated file which the
    // next `--fresh` run then trusted (its member skip keys on mere existence).
    const body = "A,B\n1,one\n2,two\n";
    const zip_bytes = try buildStoreZip(alloc, "rows.csv", body, 0xDEADBEEF);
    defer alloc.free(zip_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zip", .data = zip_bytes });

    var f = try tmp.dir.openFile(io, "bad.zip", .{});
    defer f.close(io);
    var archive: zipstream.Archive = undefined;
    try archive.init(io, alloc, f);
    defer archive.deinit();

    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);
    var wbuf: [OUT_FILE_BUF_SIZE]u8 = undefined;

    try std.testing.expectError(error.ZipEntryCorrupt, unpackOneEntry(
        io,
        &archive,
        &archive.entries.items[0],
        "rows.csv",
        tmp.dir,
        window,
        &wbuf,
    ));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "rows.csv", .{}));
}
