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

/// Cap on captured bxp-cli stdout/stderr (the Child.run default is only 50 KB).
const MAX_OUTPUT_BYTES: usize = 16 * 1024 * 1024;
/// Cap on a single read-back output file.
const MAX_FILE_BYTES: usize = 16 * 1024 * 1024;
/// Cap on the sanitized workspace-id length.
const MAX_UID_LEN: usize = 64;

const OutputFile = struct { name: []const u8, content: []const u8 };

/// Run a simulation and serialize the JSON report into `out`. Logical failures
/// (template not found, unsupported input, spawn/IO problems) come back as
/// `{"ok":false,"error":...}` JSON, not Zig errors — only OOM/unexpected
/// propagates to the caller.
pub fn simulate(
    a: std.mem.Allocator,
    config_text: []const u8,
    template: []const u8,
    csv_text: []const u8,
    workspace_id: ?[]const u8,
    out: *std.ArrayList(u8),
) !void {
    const json = try run(a, config_text, template, csv_text, workspace_id);
    try out.appendSlice(a, json);
}

fn run(
    a: std.mem.Allocator,
    config_text: []const u8,
    template: []const u8,
    csv_text: []const u8,
    workspace_id: ?[]const u8,
) ![]u8 {
    // 1. Introspect the template's input shape and reject what we can't stage.
    const io = try inspect.templateIo(a, config_text, template);
    if (!io.found) return errJson(a, "template not found in config", template);
    if (io.has_xlsx_sheet) return errJson(a, "xlsx-input templates cannot be simulated from inline CSV", template);
    if (!io.csv_input) return errJson(a, "only CSV-input templates can be simulated (file_type_in must be csv)", template);
    if (io.file_pattern_in.len == 0) return errJson(a, "template is missing required file_pattern_in", template);

    // 2. Locate the co-located bxp-cli (shared bxp-gui bundle).
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&exe_dir_buf) catch
        return errJson(a, "cannot resolve own executable directory", "");
    const cli_name = if (builtin.os.tag == .windows) "bxp-cli.exe" else "bxp-cli";
    const cli_path = try std.fs.path.join(a, &.{ exe_dir, cli_name });
    std.fs.cwd().access(cli_path, .{}) catch
        return errJson(a, "bxp-cli binary not found next to bxp-mcp", cli_path);

    // 3. Stable, reused scratch workspace (no per-call temp litter).
    const uid = try sanitize(a, workspace_id orelse template);
    const tmp_base = tmpDir(a);
    const workspace = try std.fs.path.join(a, &.{ tmp_base, "bxp-mcp-sim", uid });
    const data_dir = try std.fs.path.join(a, &.{ workspace, "data" });
    const config_path = try std.fs.path.join(a, &.{ workspace, "config.json" });

    // Fresh contents each run, stable path: wipe then recreate. Left in place
    // afterwards so the agent (or user) can inspect the run's files.
    std.fs.cwd().deleteTree(workspace) catch {};
    std.fs.cwd().makePath(data_dir) catch
        return errJson(a, "cannot create scratch workspace", workspace);

    // 4. Stage config (verbatim) + the input CSV, named so its suffix matches
    //    file_pattern_in (".csv" → input.csv, "_cash.csv" → input_cash.csv).
    const input_name = try std.fmt.allocPrint(a, "input{s}", .{io.file_pattern_in});
    const input_path = try std.fs.path.join(a, &.{ data_dir, input_name });
    std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = config_text }) catch
        return errJson(a, "cannot write scratch config", config_path);
    std.fs.cwd().writeFile(.{ .sub_path = input_path, .data = csv_text }) catch
        return errJson(a, "cannot write scratch input", input_path);

    // 5. Spawn bxp-cli — the actual run. --data overrides the template's data_dir.
    const result = std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ cli_path, "--config", config_path, "--template", template, "--data", data_dir },
        .max_output_bytes = MAX_OUTPUT_BYTES,
    }) catch |err|
        return errJson(a, "bxp-cli spawn failed", @errorName(err));

    const exit_code: i32 = switch (result.term) {
        .Exited => |c| @intCast(c),
        else => -1,
    };

    // 6. Read produced output(s): every file in data_dir that isn't the input.
    //    (combined_output can add a second file; report all.)
    var outputs: std.ArrayList(OutputFile) = .empty;
    {
        var d = std.fs.cwd().openDir(data_dir, .{ .iterate = true }) catch
            return errJson(a, "cannot reopen scratch data dir", data_dir);
        defer d.close();
        var it = d.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.eql(u8, entry.name, input_name)) continue;
            const content = d.readFileAlloc(a, entry.name, MAX_FILE_BYTES) catch continue;
            try outputs.append(a, .{ .name = try a.dupe(u8, entry.name), .content = content });
        }
    }

    // 7. bxp-mcp's own diff: input vs output record counts → outcome status.
    const input_records = countRecords(csv_text);
    var output_records: usize = 0;
    for (outputs.items) |o| output_records += countRecords(o.content);

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
        try jw.objectField("records");
        try jw.write(countRecords(o.content));
        try jw.objectField("csv");
        try jw.write(o.content);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("summary");
    try jw.write(r.summary);
    try jw.objectField("diagnostics");
    try jw.write(r.diagnostics);
    try jw.objectField("workspace");
    try jw.write(r.workspace);
    try jw.endObject();
    return aw.toOwnedSlice();
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
/// arena-owned (env reads) or a static literal.
fn tmpDir(a: std.mem.Allocator) []const u8 {
    const keys = [_][]const u8{ "TMPDIR", "TMP", "TEMP" };
    for (keys) |k| {
        if (std.process.getEnvVarOwned(a, k)) |v| {
            if (v.len > 0) return v;
        } else |_| {}
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
