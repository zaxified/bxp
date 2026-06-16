// bxp-mcp — bxp_simulate orchestration
//
// Runs a full conversion the stateless inspect tools cannot: it stages the
// agent's config + input CSV in a scratch workspace, spawns the co-located
// bxp-cli (the workhorse) to do the actual run, reads the produced output back,
// and returns a structured report. bxp-mcp does all the plumbing; bxp-cli only
// runs — the agent just thinks about the config.
//
// No new bxp-cli flags: the run uses the existing --config / --template / --data
// surface, with --data pointing the chosen template at the scratch data dir, so
// the agent's config is staged verbatim (its data_dir is left untouched).

const std = @import("std");
const builtin = @import("builtin");
const inspect = @import("inspect");
const btrace = @import("btrace");
const progress = @import("progress.zig");
const Progress = progress.Progress;

/// Cap on captured bxp-cli stdout/stderr (the Child.run default is only 50 KB).
const MAX_OUTPUT_BYTES: usize = 16 * 1024 * 1024;
/// Cap on a single read-back output file.
const MAX_FILE_BYTES: usize = 16 * 1024 * 1024;
/// Cap on the read-back BXTB sidecar trace file.
const MAX_TRACE_BYTES: usize = 16 * 1024 * 1024;
/// Max per-row entries echoed back per trace category (count is always exact;
/// the sample is capped so a large run can't bloat the JSON-RPC response).
const MAX_TRACE_SAMPLE: usize = 200;
/// Cap on the sanitized workspace-id length.
const MAX_UID_LEN: usize = 64;

/// A produced output file. `read_error` is set (and `content` empty) when the
/// file could not be read back — e.g. it exceeds `MAX_FILE_BYTES` — so the
/// report surfaces it explicitly instead of silently dropping it.
const OutputFile = struct { name: []const u8, content: []const u8, read_error: ?[]const u8 = null };

/// Run a simulation and serialize the JSON report into `out`. Logical failures
/// (template not found, unsupported input, spawn/IO problems) come back as
/// `{"ok":false,"error":...}` JSON, not Zig errors — only OOM/unexpected
/// propagates to the caller.
pub fn simulate(
    io: std.Io,
    env: *const std.process.Environ.Map,
    a: std.mem.Allocator,
    config_text: []const u8,
    template: []const u8,
    csv_text: []const u8,
    workspace_id: ?[]const u8,
    prog: ?Progress,
    out: *std.ArrayList(u8),
) !void {
    const json = try run(io, env, a, config_text, template, csv_text, workspace_id, prog);
    try out.appendSlice(a, json);
}

fn run(
    io: std.Io,
    env: *const std.process.Environ.Map,
    a: std.mem.Allocator,
    config_text: []const u8,
    template: []const u8,
    csv_text: []const u8,
    workspace_id: ?[]const u8,
    prog: ?Progress,
) ![]u8 {
    progress.report(prog, 1, 4, "validating template");
    // 1. Introspect the template's input shape and reject what we can't stage.
    const tio = try inspect.templateIo(a, config_text, template);
    if (!tio.found) return errJson(a, "template not found in config", template);
    if (tio.has_xlsx_sheet) return errJson(a, "xlsx-input templates cannot be simulated from inline CSV", template);
    if (!tio.csv_input) return errJson(a, "only CSV-input templates can be simulated (file_type_in must be csv)", template);
    if (tio.file_pattern_in.len == 0) return errJson(a, "template is missing required file_pattern_in", template);
    // file_pattern_in is folded into the staged input filename (input<suffix>)
    // and comes back raw from the config (templateIo does not sanitize it). A
    // value containing a path separator or ".." would let path.join + the
    // kernel's ".." resolution climb out of the confined scratch workspace and
    // write the agent-supplied CSV to an arbitrary path — defeating the same
    // sandbox boundary the workspace-id sanitizer enforces. A legitimate
    // pattern is a pure filename suffix (".csv", "_cash.csv"), so reject any
    // path-shape input here, before staging.
    if (std.mem.indexOfAny(u8, tio.file_pattern_in, "/\\") != null or
        std.mem.indexOf(u8, tio.file_pattern_in, "..") != null)
        return errJson(a, "file_pattern_in must be a plain filename suffix (no path separators or '..')", tio.file_pattern_in);

    // 2. Locate the co-located bxp-cli (shared bxp-gui bundle).
    var exe_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_dir_n = std.process.executableDirPath(io, &exe_dir_buf) catch
        return errJson(a, "cannot resolve own executable directory", "");
    const exe_dir = exe_dir_buf[0..exe_dir_n];
    const cli_name = if (builtin.os.tag == .windows) "bxp-cli.exe" else "bxp-cli";
    const cli_path = try std.Io.Dir.path.join(a, &.{ exe_dir, cli_name });
    std.Io.Dir.cwd().access(io, cli_path, .{}) catch
        return errJson(a, "bxp-cli binary not found next to bxp-mcp", cli_path);

    // 3. Stable, reused scratch workspace (no per-call temp litter).
    const uid = try sanitize(a, workspace_id orelse template);
    const tmp_base = tmpDir(env);
    const workspace = try std.Io.Dir.path.join(a, &.{ tmp_base, "bxp-mcp-sim", uid });
    const data_dir = try std.Io.Dir.path.join(a, &.{ workspace, "data" });
    const config_path = try std.Io.Dir.path.join(a, &.{ workspace, "config.json" });
    const trace_path = try std.Io.Dir.path.join(a, &.{ workspace, "trace.bxtb" });

    // Fresh contents each run, stable path: wipe then recreate. Left in place
    // afterwards so the agent (or user) can inspect the run's files.
    std.Io.Dir.cwd().deleteTree(io, workspace) catch {};
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch
        return errJson(a, "cannot create scratch workspace", workspace);

    // 4. Stage config (verbatim) + the input CSV, named so its suffix matches
    //    file_pattern_in (".csv" → input.csv, "_cash.csv" → input_cash.csv).
    const input_name = try std.fmt.allocPrint(a, "input{s}", .{tio.file_pattern_in});
    const input_path = try std.Io.Dir.path.join(a, &.{ data_dir, input_name });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = config_text }) catch
        return errJson(a, "cannot write scratch config", config_path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = csv_text }) catch
        return errJson(a, "cannot write scratch input", input_path);

    progress.report(prog, 2, 4, "staging workspace");

    // 5. Spawn bxp-cli — the actual run. --data overrides the template's
    //    data_dir; --trace-file writes a sidecar BXTB stream (full per-row
    //    detail, independent of stdout) we read back below for the trace report.
    progress.report(prog, 3, 4, "running conversion");
    const result = std.process.run(a, io, .{
        .argv = &.{ cli_path, "--config", config_path, "--template", template, "--data", data_dir, "--trace-file", trace_path },
        .stdout_limit = .limited(MAX_OUTPUT_BYTES),
        .stderr_limit = .limited(MAX_OUTPUT_BYTES),
    }) catch |err|
        return errJson(a, "bxp-cli spawn failed", @errorName(err));

    const exit_code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };

    progress.report(prog, 4, 4, "reading output and trace");

    // Read back the BXTB sidecar (best-effort: a missing/empty file just means
    // an empty trace section, never a simulation failure).
    const trace_bytes = std.Io.Dir.cwd().readFileAlloc(io, trace_path, a, .limited(MAX_TRACE_BYTES)) catch &.{};

    // 6. Read produced output(s): every file in data_dir that isn't the input.
    //    (combined_output can add a second file; report all.)
    var outputs: std.ArrayList(OutputFile) = .empty;
    {
        var d = std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true }) catch
            return errJson(a, "cannot reopen scratch data dir", data_dir);
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.eql(u8, entry.name, input_name)) continue;
            const name = try a.dupe(u8, entry.name);
            // A read failure (too large, IO error) is reported as a marked
            // output entry, never silently skipped.
            const content = d.readFileAlloc(io, entry.name, a, .limited(MAX_FILE_BYTES)) catch |err| {
                try outputs.append(a, .{ .name = name, .content = "", .read_error = @errorName(err) });
                continue;
            };
            try outputs.append(a, .{ .name = name, .content = content });
        }
    }

    // 7. bxp-mcp's own diff: input vs output record counts → outcome status.
    //    Counts are data rows (header excluded) so they line up with the BXTB
    //    trace's source_rows / written_rows.
    const input_records = countDataRecords(csv_text);
    var output_records: usize = 0;
    for (outputs.items) |o| {
        if (o.read_error == null) output_records += countDataRecords(o.content);
    }

    return buildReport(a, .{
        .template = template,
        .workspace = workspace,
        .exit_code = exit_code,
        .input_csv = csv_text,
        .input_records = input_records,
        .output_records = output_records,
        .outputs = outputs.items,
        .summary = result.stdout,
        .diagnostics = result.stderr,
        .trace_bytes = trace_bytes,
    });
}

const Report = struct {
    template: []const u8,
    workspace: []const u8,
    exit_code: i32,
    input_csv: []const u8,
    input_records: usize,
    output_records: usize,
    outputs: []const OutputFile,
    summary: []const u8,
    diagnostics: []const u8,
    trace_bytes: []const u8,
};

/// `ok = true` means the run *happened* — consult `exit_code` / `status` /
/// `diagnostics` for its outcome (bxp-cli: 0 = ok, 2 = warnings, 1 = error).
/// `ok = false` is reserved for orchestration failures that prevented a run
/// (see `errJson`).
fn buildReport(a: std.mem.Allocator, r: Report) ![]u8 {
    const status: []const u8 = switch (r.exit_code) {
        0 => "ok",
        2 => "warnings",
        else => "error",
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("ok");
    try jw.write(true);
    try jw.objectField("template");
    try jw.write(r.template);
    try jw.objectField("exit_code");
    try jw.write(r.exit_code);
    try jw.objectField("status");
    try jw.write(status);
    try jw.objectField("input");
    try jw.beginObject();
    try jw.objectField("records");
    try jw.write(r.input_records);
    try jw.objectField("csv");
    try jw.write(r.input_csv);
    try jw.endObject();
    try jw.objectField("output_records");
    try jw.write(r.output_records);
    try jw.objectField("outputs");
    try jw.beginArray();
    for (r.outputs) |o| {
        try jw.beginObject();
        try jw.objectField("file");
        try jw.write(o.name);
        if (o.read_error) |e| {
            try jw.objectField("error");
            try jw.write(e);
        } else {
            try jw.objectField("records");
            try jw.write(countDataRecords(o.content));
            try jw.objectField("csv");
            try jw.write(o.content);
        }
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("summary");
    try jw.write(r.summary);
    try jw.objectField("diagnostics");
    try jw.write(r.diagnostics);
    try jw.objectField("trace");
    try writeTrace(a, &jw, r.trace_bytes, r.input_csv);
    try jw.objectField("workspace");
    try jw.write(r.workspace);
    try jw.endObject();
    return aw.toOwnedSlice();
}

// ── BXTB sidecar → JSON per-row trace ────────────────────────────────────────

const FilteredSample = struct { input_row: usize, source_offset: u64, reason: []const u8 };
const ErrorSample = struct {
    input_row: usize,
    source_offset: u64,
    variable: []const u8,
    kind: []const u8,
    detail: []const u8,
    origin: []const u8,
};
const OutputSample = struct {
    input_row: usize,
    source_offset: u64,
    output_idx: u64,
    rule: i32,
    action: []const u8,
};

/// One pass over the BXTB frames: exact per-category counts plus a capped
/// sample of each. `source_locator` byte offsets are resolved to 1-based input
/// line numbers (the staged input file is `input_csv` verbatim).
const TraceSummary = struct {
    available: bool = false,
    source_rows: u64 = 0,
    written_rows: u64 = 0,
    errors: u64 = 0,
    warnings: u64 = 0,
    filtered_count: usize = 0,
    error_count: usize = 0,
    output_count: usize = 0,
    prepass_count: usize = 0,
    filtered: []const FilteredSample = &.{},
    row_errors: []const ErrorSample = &.{},
    outputs: []const OutputSample = &.{},
};

fn parseTrace(a: std.mem.Allocator, trace_bytes: []const u8, input_csv: []const u8) TraceSummary {
    var ts: TraceSummary = .{};
    if (trace_bytes.len == 0) return ts;
    var r: std.Io.Reader = .fixed(trace_bytes);
    var reader = btrace.Reader.init(&r, a) catch return ts; // bad/short magic → unavailable
    ts.available = true;

    var filtered: std.ArrayList(FilteredSample) = .empty;
    var row_errors: std.ArrayList(ErrorSample) = .empty;
    var outputs: std.ArrayList(OutputSample) = .empty;

    // Build the newline-offset index once (O(csv_len)); every per-sample
    // line lookup is then an O(log n) binary search. Previously each of up
    // to 3×MAX_TRACE_SAMPLE samples rescanned the whole CSV from offset 0,
    // i.e. O(samples × csv_len) over an uncapped inline payload.
    const line_index = LineIndex{ .newlines = buildLineIndex(a, input_csv) };

    while (reader.nextFrame() catch null) |frame| {
        switch (frame) {
            .file_end => |fe| {
                ts.source_rows += fe.source_rows;
                ts.written_rows += fe.written_rows;
                ts.errors += fe.errors;
                ts.warnings += fe.warnings;
            },
            .filtered_row => |fr| {
                ts.filtered_count += 1;
                if (filtered.items.len < MAX_TRACE_SAMPLE) filtered.append(a, .{
                    .input_row = line_index.lineAt(fr.source_locator),
                    .source_offset = fr.source_locator,
                    .reason = fr.reason,
                }) catch {};
            },
            .error_row => |er| {
                ts.error_count += 1;
                if (row_errors.items.len < MAX_TRACE_SAMPLE) row_errors.append(a, .{
                    .input_row = line_index.lineAt(er.source_locator),
                    .source_offset = er.source_locator,
                    .variable = er.var_name,
                    .kind = er.error_kind,
                    .detail = er.detail,
                    .origin = er.origin,
                }) catch {};
            },
            .output_row => |orw| {
                ts.output_count += 1;
                if (outputs.items.len < MAX_TRACE_SAMPLE) outputs.append(a, .{
                    .input_row = line_index.lineAt(orw.source_locator),
                    .source_offset = orw.source_locator,
                    .output_idx = orw.output_idx,
                    .rule = orw.rule_idx,
                    .action = orw.action,
                }) catch {};
            },
            .prepass_entry => ts.prepass_count += 1,
            .file_start, .done => {},
        }
    }

    ts.filtered = filtered.items;
    ts.row_errors = row_errors.items;
    ts.outputs = outputs.items;
    return ts;
}

/// Sorted newline offsets of a CSV, enabling O(log n) line-number lookups
/// instead of an O(n) from-offset-0 rescan per query.
const LineIndex = struct {
    newlines: []const u64,

    /// 1-based physical line number of byte `offset` (header = line 1) —
    /// the count of newlines strictly before `offset`, plus one. Matches
    /// the former linear scan exactly (a newline AT `offset` is not counted;
    /// offsets past EOF count every newline).
    fn lineAt(self: LineIndex, offset: u64) usize {
        var lo: usize = 0;
        var hi: usize = self.newlines.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.newlines[mid] < offset) lo = mid + 1 else hi = mid;
        }
        return lo + 1;
    }
};

/// One pass over `csv` collecting every `\n` byte offset (ascending by
/// construction). On OOM returns whatever was collected so far — a degraded
/// (possibly low) line number is preferable to failing the whole trace.
fn buildLineIndex(a: std.mem.Allocator, csv: []const u8) []const u64 {
    var nl: std.ArrayList(u64) = .empty;
    for (csv, 0..) |c, i| {
        if (c == '\n') nl.append(a, @intCast(i)) catch break;
    }
    return nl.items;
}

/// Emit the `trace` value: `{"available":false}` when no usable BXTB was
/// produced, otherwise the aggregate stats + capped per-row samples.
fn writeTrace(a: std.mem.Allocator, jw: *std.json.Stringify, trace_bytes: []const u8, input_csv: []const u8) !void {
    const ts = parseTrace(a, trace_bytes, input_csv);
    try jw.beginObject();
    try jw.objectField("available");
    try jw.write(ts.available);
    if (ts.available) {
        try jw.objectField("source_rows");
        try jw.write(ts.source_rows);
        try jw.objectField("written_rows");
        try jw.write(ts.written_rows);
        try jw.objectField("errors");
        try jw.write(ts.errors);
        try jw.objectField("warnings");
        try jw.write(ts.warnings);

        try jw.objectField("filtered");
        try jw.beginObject();
        try jw.objectField("count");
        try jw.write(ts.filtered_count);
        try jw.objectField("sample");
        try jw.beginArray();
        for (ts.filtered) |f| {
            try jw.beginObject();
            try jw.objectField("input_row");
            try jw.write(f.input_row);
            try jw.objectField("source_offset");
            try jw.write(f.source_offset);
            try jw.objectField("reason");
            try jw.write(f.reason);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();

        try jw.objectField("row_errors");
        try jw.beginObject();
        try jw.objectField("count");
        try jw.write(ts.error_count);
        try jw.objectField("sample");
        try jw.beginArray();
        for (ts.row_errors) |e| {
            try jw.beginObject();
            try jw.objectField("input_row");
            try jw.write(e.input_row);
            try jw.objectField("source_offset");
            try jw.write(e.source_offset);
            try jw.objectField("variable");
            try jw.write(e.variable);
            try jw.objectField("kind");
            try jw.write(e.kind);
            try jw.objectField("detail");
            try jw.write(e.detail);
            try jw.objectField("origin");
            try jw.write(e.origin);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();

        try jw.objectField("output_rows");
        try jw.beginObject();
        try jw.objectField("count");
        try jw.write(ts.output_count);
        try jw.objectField("sample");
        try jw.beginArray();
        for (ts.outputs) |o| {
            try jw.beginObject();
            try jw.objectField("input_row");
            try jw.write(o.input_row);
            try jw.objectField("source_offset");
            try jw.write(o.source_offset);
            try jw.objectField("output_idx");
            try jw.write(o.output_idx);
            try jw.objectField("rule");
            try jw.write(o.rule);
            try jw.objectField("action");
            try jw.write(o.action);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();

        try jw.objectField("prepass_entries");
        try jw.write(ts.prepass_count);
    }
    try jw.endObject();
}

fn errJson(a: std.mem.Allocator, msg: []const u8, detail: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("ok");
    try jw.write(false);
    try jw.objectField("error");
    try jw.write(msg);
    try jw.objectField("detail");
    try jw.write(detail);
    try jw.endObject();
    return aw.toOwnedSlice();
}

/// Count non-empty records. bxp CSV uses lazy quotes (a bare `\n` always ends a
/// record — no multi-line quoted fields), so a line count is a record count.
fn countRecords(bytes: []const u8) usize {
    var n: usize = 0;
    var has_content = false;
    for (bytes) |c| {
        if (c == '\n') {
            if (has_content) n += 1;
            has_content = false;
        } else if (c != '\r') {
            has_content = true;
        }
    }
    if (has_content) n += 1;
    return n;
}

/// Data-row count: non-empty lines minus the header row (every bxp CSV — input
/// and output — carries a header). Lines up with the BXTB trace's per-file
/// `source_rows` / `written_rows`, unlike the raw line count.
fn countDataRecords(bytes: []const u8) usize {
    const n = countRecords(bytes);
    return if (n > 0) n - 1 else 0;
}

/// Filesystem-safe workspace id: keep [A-Za-z0-9_-], map everything else to
/// '_', cap the length, never empty.
fn sanitize(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const n = @min(s.len, MAX_UID_LEN);
    if (n == 0) return a.dupe(u8, "_");
    const buf = try a.alloc(u8, n);
    for (s[0..n], 0..) |c, i| {
        buf[i] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
    }
    return buf;
}

/// Best-effort temp base: honor TMPDIR/TMP/TEMP, else "/tmp". Returned slice is
/// borrowed from the process environ map (process-lifetime) or a static literal.
fn tmpDir(env: *const std.process.Environ.Map) []const u8 {
    const keys = [_][]const u8{ "TMPDIR", "TMP", "TEMP" };
    for (keys) |k| {
        if (env.get(k)) |v| {
            if (v.len > 0) return v;
        }
    }
    return "/tmp";
}

test "countRecords: non-empty lines, trailing-newline and CRLF agnostic" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), countRecords(""));
    try t.expectEqual(@as(usize, 1), countRecords("a,b,c")); // no trailing \n
    try t.expectEqual(@as(usize, 2), countRecords("h1,h2\n1,2\n"));
    try t.expectEqual(@as(usize, 2), countRecords("h1,h2\n1,2")); // last line, no \n
    try t.expectEqual(@as(usize, 2), countRecords("h1,h2\r\n1,2\r\n")); // CRLF
    try t.expectEqual(@as(usize, 1), countRecords("a\n\n\n")); // blank lines ignored
}

test "countDataRecords: excludes the header row, never underflows" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), countDataRecords("")); // empty → 0, no underflow
    try t.expectEqual(@as(usize, 0), countDataRecords("h1,h2")); // header only
    try t.expectEqual(@as(usize, 1), countDataRecords("h1,h2\n1,2\n")); // 1 data row
    try t.expectEqual(@as(usize, 2), countDataRecords("h1,h2\n1,2\n3,4")); // no trailing \n
}

test "sanitize: keeps [A-Za-z0-9_-], maps the rest, never empty, length-capped" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("abc_DEF-9", try sanitize(a, "abc/DEF-9"));
    try t.expectEqualStrings("a_b_c", try sanitize(a, "a b.c"));
    try t.expectEqualStrings("_", try sanitize(a, ""));
    const long = try sanitize(a, "x" ** 100);
    try t.expectEqual(MAX_UID_LEN, long.len);
}
