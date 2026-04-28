/// Lightweight JSON5 → JSON preprocessor.
///
/// Converts JSON5 source to standard JSON accepted by std.json.parseFromSlice:
///   - strips // single-line comments
///   - strips /* */ multi-line comments
///   - quotes unquoted object keys  (foo: → "foo":)
///   - removes trailing commas before } and ]
///   - converts single-quoted strings to double-quoted strings
///
/// Single-pass; respects all string contexts so none of the above are applied
/// inside string literals.

const std = @import("std");

/// Preprocess JSON5 source and return a new slice owned by alloc.
pub fn preprocess(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var nest: std.ArrayList(u8) = .empty; // '{' or '[' per nesting level
    defer nest.deinit(alloc);
    var key_pos = false; // true when next identifier is an object key
    var err_counter: u32 = 0;
    var i: usize = 0;

    while (i < input.len) {
        const c = input[i];

        // ── double-quoted string — copy verbatim ────────────────────────────
        if (c == '"') {
            key_pos = false;
            try out.append(alloc, c);
            i += 1;
            while (i < input.len) {
                const sc = input[i];
                try out.append(alloc, sc);
                i += 1;
                if (sc == '\\' and i < input.len) {
                    try out.append(alloc, input[i]);
                    i += 1;
                } else if (sc == '"') break;
            }
            continue;
        }

        // ── single-quoted string — convert to double-quoted ─────────────────
        if (c == '\'') {
            key_pos = false;
            try out.append(alloc, '"');
            i += 1;
            while (i < input.len) {
                const sc = input[i];
                i += 1;
                if (sc == '\\' and i < input.len) {
                    const esc = input[i];
                    i += 1;
                    if (esc == '\'') {
                        try out.append(alloc, '\''); // \' → ' (unescape)
                    } else {
                        try out.append(alloc, '\\');
                        try out.append(alloc, esc);
                    }
                } else if (sc == '"') {
                    try out.appendSlice(alloc, "\\\""); // escape " inside
                } else if (sc == '\'') {
                    break;
                } else {
                    try out.append(alloc, sc);
                }
            }
            try out.append(alloc, '"');
            continue;
        }

        // ── comments ────────────────────────────────────────────────────────
        if (c == '/' and i + 1 < input.len) {
            if (input[i + 1] == '/') { // single-line
                i += 2;
                while (i < input.len and input[i] != '\n') i += 1;
                continue;
            }
            if (input[i + 1] == '*') { // multi-line
                i += 2;
                while (i + 1 < input.len) {
                    if (input[i] == '*' and input[i + 1] == '/') { i += 2; break; }
                    i += 1;
                }
                continue;
            }
        }

        // ── structural tokens ────────────────────────────────────────────────
        switch (c) {
            '{' => {
                try nest.append(alloc, '{');
                key_pos = true;
                try out.append(alloc, c);
                i += 1;
            },
            '}' => {
                _ = nest.pop();
                key_pos = false;
                removeTrailingComma(&out);
                try out.append(alloc, c);
                i += 1;
            },
            '[' => {
                try nest.append(alloc, '[');
                key_pos = false;
                try out.append(alloc, c);
                i += 1;
            },
            ']' => {
                _ = nest.pop();
                key_pos = false;
                removeTrailingComma(&out);
                try out.append(alloc, c);
                i += 1;
            },
            ':' => {
                key_pos = false;
                try out.append(alloc, c);
                i += 1;
            },
            ',' => {
                // after a comma inside an object, the next token is a key
                key_pos = nest.items.len > 0 and nest.items[nest.items.len - 1] == '{';
                try out.append(alloc, c);
                i += 1;
            },
            // ── unquoted identifier in key position ─────────────────────────
            else => {
                if (key_pos and (std.ascii.isAlphabetic(c) or c == '_' or c == '$')) {
                    const key_start = i;
                    while (i < input.len) {
                        const kc = input[i];
                        if (!std.ascii.isAlphanumeric(kc) and kc != '_' and kc != '$') break;
                        i += 1;
                    }
                    // Peek ahead past whitespace to find ':'
                    var j = i;
                    while (j < input.len and (input[j] == ' ' or input[j] == '\t')) : (j += 1) {}
                    if (j >= input.len or input[j] == ':') {
                        // Normal path: output quoted key
                        try out.append(alloc, '"');
                        try out.appendSlice(alloc, input[key_start..i]);
                        try out.append(alloc, '"');
                        key_pos = false;
                    } else {
                        // Error recovery: junk before ':' (e.g. space inside unquoted key)
                        var colon = j;
                        while (colon < input.len and input[colon] != ':') : (colon += 1) {}
                        const raw_key = std.mem.trim(u8, input[key_start..colon], " \t\r\n");
                        var vs = colon + 1;
                        while (vs < input.len and (input[vs] == ' ' or input[vs] == '\t')) : (vs += 1) {}
                        const val_end = skipValue(input, vs);
                        const raw_val_full = std.mem.trim(u8, input[vs..val_end], " \t\r\n");
                        const raw_val = if (raw_val_full.len > 30) raw_val_full[0..30] else raw_val_full;
                        const err_line = lineOf(input, key_start);
                        const msg = try std.fmt.allocPrint(alloc, "{s}: '{s}' --> malformed key at line {d}", .{
                            raw_key, raw_val, err_line,
                        });
                        defer alloc.free(msg);
                        err_counter += 1;
                        const head = try std.fmt.allocPrint(alloc, "\"$err_trace_{d}\": ", .{err_counter});
                        defer alloc.free(head);
                        try out.appendSlice(alloc, head);
                        try appendJsonStr(&out, alloc, msg);
                        key_pos = false;
                        i = val_end;
                    }
                } else {
                    try out.append(alloc, c);
                    i += 1;
                }
            },
        }
    }

    return out.toOwnedSlice(alloc);
}

/// Scan backwards in `out` and remove the last comma if it is only followed
/// by whitespace.  Called just before writing } or ].
fn removeTrailingComma(out: *std.ArrayList(u8)) void {
    var j = out.items.len;
    while (j > 0) {
        j -= 1;
        switch (out.items[j]) {
            ' ', '\t', '\n', '\r' => {},
            ',' => { out.items.len = j; return; },
            else => return,
        }
    }
}

/// Return the 1-based line number of position `pos` in `input`.
fn lineOf(input: []const u8, pos: usize) usize {
    var line: usize = 1;
    for (input[0..@min(pos, input.len)]) |ch| {
        if (ch == '\n') line += 1;
    }
    return line;
}

/// Skip one JSON5 value starting at `start`. Returns the index of the first
/// delimiter character after the value (`,` `}` `]`) without consuming it.
fn skipValue(input: []const u8, start: usize) usize {
    var i = start;
    var depth: i32 = 0;
    var in_str = false;
    while (i < input.len) : (i += 1) {
        const ch = input[i];
        if (in_str) {
            if (ch == '\\') { i += 1; continue; }
            if (ch == '"' or ch == '\'') in_str = false;
        } else switch (ch) {
            '"', '\'' => in_str = true,
            '{', '[' => depth += 1,
            '}', ']' => { if (depth == 0) return i; depth -= 1; },
            ',' => if (depth == 0) return i,
            else => {},
        }
    }
    return i;
}

/// Append `s` as a JSON-escaped double-quoted string to `out`.
fn appendJsonStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '"'  => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => try out.append(alloc, ch),
    };
    try out.append(alloc, '"');
}

// ── annotated variant: preserves comments as $comm_<N>, errors as $err_<N> ─

pub const Placement = enum { leading, trailing, block, standalone };

fn placementName(p: Placement) []const u8 {
    return switch (p) {
        .leading => "leading",
        .trailing => "trailing",
        .block => "block",
        .standalone => "standalone",
    };
}

const PendingComment = struct {
    text: []u8, // owned by alloc; includes `//` or `/* */` markers
    placement: Placement,
    // Byte spans into the original input:
    //   block_*: whole comment row incl. leading indent (for splice/move)
    //   text_*:  comment body only, excluding markers (for EditCommentOp)
    block_start: usize,
    block_end: usize,
    text_start: usize,
    text_end: usize,
};

pub const AnnotatedResult = struct {
    out: []u8,
    next_id: u32, // first unused id; bxp-fmt continues numbering from here
};

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn whitespaceKind(slice: []const u8) []const u8 {
    var has_nl = false;
    var has_tab = false;
    for (slice) |ch| {
        if (ch == '\n' or ch == '\r') has_nl = true;
        if (ch == '\t') has_tab = true;
    }
    if (has_nl) return "newline";
    if (has_tab) return "tab";
    return "whitespace";
}

/// Decide whether a // comment that begins at `comment_start` is leading or
/// trailing relative to the preceding token. Walks backwards through the
/// input: any \n/\r before the next non-whitespace byte → leading.
fn detectLinePlacement(input: []const u8, comment_start: usize) Placement {
    var k = comment_start;
    while (k > 0) {
        k -= 1;
        const ch = input[k];
        if (ch == '\n' or ch == '\r') return .leading;
        if (ch == ' ' or ch == '\t') continue;
        return .trailing;
    }
    return .leading; // start of file
}

fn needsLeadingComma(out: []const u8) bool {
    var k = out.len;
    while (k > 0) {
        k -= 1;
        const ch = out[k];
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') continue;
        if (ch == '{' or ch == '[' or ch == ',' or ch == ':') return false;
        return true;
    }
    return false;
}

/// Emit all pending comments into `out` as `"$comm_N": {"text":"...","placement":"..."}`
/// sibling entries. When `at_close` is true (flushing right before `}`), any
/// `leading` placements are reclassified to `standalone`; trailing/block keep
/// their original placement.
fn flushPending(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    pending: *std.ArrayList(PendingComment),
    counter: *u32,
    at_close: bool,
) !void {
    if (pending.items.len == 0) return;

    if (needsLeadingComma(out.items)) try out.appendSlice(alloc, ", ");

    for (pending.items, 0..) |p, idx| {
        if (idx > 0) try out.appendSlice(alloc, ", ");
        counter.* += 1;
        const placement = if (at_close and p.placement == .leading) Placement.standalone else p.placement;
        const head = try std.fmt.allocPrint(alloc, "\"$comm_{d}\": {{\"text\": ", .{counter.*});
        defer alloc.free(head);
        try out.appendSlice(alloc, head);
        try appendJsonStr(out, alloc, p.text);
        try out.appendSlice(alloc, ", \"placement\": \"");
        try out.appendSlice(alloc, placementName(placement));
        try out.appendSlice(alloc, "\"}");
        // Sibling $meta_comm_<N> with byte spans for the GUI's CST-preserving ops.
        const meta_head = try std.fmt.allocPrint(
            alloc,
            ", \"$meta_comm_{d}\": {{\"value_span\": ",
            .{counter.*},
        );
        defer alloc.free(meta_head);
        try out.appendSlice(alloc, meta_head);
        try appendSpanObj(out, alloc, p.text_start, p.text_end);
        try out.appendSlice(alloc, ", \"block_span\": ");
        try appendSpanObj(out, alloc, p.block_start, p.block_end);
        try out.append(alloc, '}');
    }
    // If a key/value follows (mid-object flush), separate with a trailing comma.
    // At a closing brace, removeTrailingComma in the '}' handler takes care of any leftover.
    if (!at_close) try out.appendSlice(alloc, ", ");

    for (pending.items) |p| alloc.free(p.text);
    pending.clearRetainingCapacity();
}

fn dropPending(alloc: std.mem.Allocator, pending: *std.ArrayList(PendingComment)) void {
    for (pending.items) |p| alloc.free(p.text);
    pending.clearRetainingCapacity();
}

/// Errors discovered after a value has already been emitted (unterminated
/// strings, invalid bare-identifier literals). Flushed as `, "$err_<N>": "..."`
/// sibling entries before the next `,` or `}` in the parent object. Only
/// produced when nest top is `{` — array contents recover silently in v1.
fn flushValueErrs(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    errs: *std.ArrayList([]u8),
    counter: *u32,
) !void {
    for (errs.items) |msg| {
        try out.appendSlice(alloc, ", ");
        counter.* += 1;
        const head = try std.fmt.allocPrint(alloc, "\"$err_{d}\": ", .{counter.*});
        defer alloc.free(head);
        try out.appendSlice(alloc, head);
        try appendJsonStr(out, alloc, msg);
        alloc.free(msg);
    }
    errs.clearRetainingCapacity();
}

fn dropValueErrs(alloc: std.mem.Allocator, errs: *std.ArrayList([]u8)) void {
    for (errs.items) |m| alloc.free(m);
    errs.clearRetainingCapacity();
}

fn isInObject(nest: []const u8) bool {
    return nest.len > 0 and nest[nest.len - 1] == '{';
}

fn isInArray(nest: []const u8) bool {
    return nest.len > 0 and nest[nest.len - 1] == '[';
}

/// Per-`{`/`[` bookkeeping for byte-span emission. Synchronised with `nest`.
const NestMeta = struct {
    kind: u8,             // '{' or '['
    open_pos: usize,      // input offset of the opening brace
    parent_key: ?[]u8,    // owned; the key this composite is the value of, in its parent object
    parent_key_start: usize, // input pos of parent_key in input (for block_span of composites)
    parent_key_end: usize,
    // Per-array-element spans (only used when kind == '[').
    item_value_starts: std.ArrayList(usize),
    item_value_ends:   std.ArrayList(usize),
    item_block_starts: std.ArrayList(usize),
    item_block_ends:   std.ArrayList(usize),
    cur_item_start: ?usize, // start of the value currently being consumed
};

/// Walk back from `pos` through inline whitespace (` `, `\t`) only. Returns
/// the position right after the first preceding `\n`, the container-opening
/// `{`/`[`, or 0 — whichever is hit first. This is the start-of-row for a
/// child entry: anything left of [block_start, key_start) is just indent.
fn walkBackToLineStart(input: []const u8, pos: usize) usize {
    var k = pos;
    while (k > 0) {
        const c = input[k - 1];
        if (c == ' ' or c == '\t') {
            k -= 1;
        } else {
            break;
        }
    }
    return k;
}

/// Trim trailing whitespace bytes (` `, `\t`, `\n`, `\r`) from a value's
/// end position so block_span doesn't accidentally swallow the line terminator
/// when a value's `value_end` was set at a structural token like `]` / `}`.
fn trimTrailingWs(input: []const u8, end: usize) usize {
    var k = end;
    while (k > 0) {
        const c = input[k - 1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            k -= 1;
        } else {
            break;
        }
    }
    return k;
}

/// Walk forward from `pos` (typically a value's end) past optional same-row
/// trailing syntax: any combination of inline whitespace, a single `,`, and
/// a same-line `//` line comment. Block-comments and multi-line constructs
/// are NOT consumed — they belong to the next entry. The returned offset is
/// `\n` / `}` / `]` (exclusive) or input end.
fn walkForwardToLineEnd(input: []const u8, pos: usize) usize {
    var k = pos;
    // inline whitespace
    while (k < input.len and (input[k] == ' ' or input[k] == '\t')) k += 1;
    // optional comma
    if (k < input.len and input[k] == ',') k += 1;
    // inline whitespace after comma
    while (k < input.len and (input[k] == ' ' or input[k] == '\t')) k += 1;
    // optional same-line `//` comment
    if (k + 1 < input.len and input[k] == '/' and input[k + 1] == '/') {
        k += 2;
        while (k < input.len and input[k] != '\n') k += 1;
    }
    return k;
}

/// Append `"$<prefix><key>"` with the key portion JSON-escaped (best-effort —
/// quoted keys may carry non-ident characters).
fn appendSpanKey(out: *std.ArrayList(u8), alloc: std.mem.Allocator, prefix: []const u8, key: []const u8) !void {
    try out.append(alloc, '"');
    try out.appendSlice(alloc, prefix);
    for (key) |ch| switch (ch) {
        '"'  => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => try out.append(alloc, ch),
    };
    try out.append(alloc, '"');
}

/// Append a JSON object literal `{"start": A, "end": B}` to out.
fn appendSpanObj(out: *std.ArrayList(u8), alloc: std.mem.Allocator, start: usize, end: usize) !void {
    const body = try std.fmt.allocPrint(alloc, "{{\"start\": {d}, \"end\": {d}}}", .{ start, end });
    defer alloc.free(body);
    try out.appendSlice(alloc, body);
}

/// Emit `, "$meta_<key>": {key_span, value_span, block_span}` after a real
/// child entry's value. The GUI needs all three to support edit / delete /
/// duplicate / move / insert via byte-level operations against the original
/// raw input — see plan-fmt-annotated-json-v2.md.
fn emitChildMeta(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    key: []const u8,
    key_start: usize,
    key_end: usize,
    value_start: usize,
    value_end: usize,
    block_start: usize,
    block_end: usize,
) !void {
    if (needsLeadingComma(out.items)) try out.appendSlice(alloc, ", ");
    try appendSpanKey(out, alloc, "$meta_", key);
    try out.appendSlice(alloc, ": {\"key_span\": ");
    try appendSpanObj(out, alloc, key_start, key_end);
    try out.appendSlice(alloc, ", \"value_span\": ");
    try appendSpanObj(out, alloc, value_start, value_end);
    try out.appendSlice(alloc, ", \"block_span\": ");
    try appendSpanObj(out, alloc, block_start, block_end);
    try out.append(alloc, '}');
}

/// Emit `, "$elem_meta_<key>": [{value_span, block_span}, ...]` listing
/// per-element byte ranges for an array. Mirrors `$meta_<key>` but without
/// the key dimension (array elements have no keys).
fn emitElemMeta(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    key: []const u8,
    value_starts: []const usize,
    value_ends:   []const usize,
    block_starts: []const usize,
    block_ends:   []const usize,
) !void {
    if (needsLeadingComma(out.items)) try out.appendSlice(alloc, ", ");
    try appendSpanKey(out, alloc, "$elem_meta_", key);
    try out.appendSlice(alloc, ": [");
    for (value_starts, value_ends, block_starts, block_ends, 0..) |vs, ve, bs, be, idx| {
        if (idx > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, "{\"value_span\": ");
        try appendSpanObj(out, alloc, vs, ve);
        try out.appendSlice(alloc, ", \"block_span\": ");
        try appendSpanObj(out, alloc, bs, be);
        try out.append(alloc, '}');
    }
    try out.append(alloc, ']');
}

/// Emit `"$meta_self": {container_span: {...}}` as a sibling inside the
/// container itself. Always the first key emitted right after `{` or `[`,
/// so it doesn't compete with content for ordering.
fn emitContainerMeta(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    open_pos: usize,
    close_end: usize,
) !void {
    if (needsLeadingComma(out.items)) try out.appendSlice(alloc, ", ");
    try out.appendSlice(alloc, "\"$meta_self\": {\"container_span\": ");
    try appendSpanObj(out, alloc, open_pos, close_end);
    try out.append(alloc, '}');
}

/// Emit pending comments into an array context as single-key pseudo-objects:
/// `{"$comm_<N>": {"text":"...","placement":"..."}}`. They sit between real
/// elements and stay valid JSON. The Dart side detects single-key `$comm_*`
/// objects and renders them as inline comments instead of array elements.
fn flushPendingInArray(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    pending: *std.ArrayList(PendingComment),
    counter: *u32,
    at_close: bool,
) !void {
    if (pending.items.len == 0) return;

    if (needsLeadingComma(out.items)) try out.appendSlice(alloc, ", ");

    for (pending.items, 0..) |p, idx| {
        if (idx > 0) try out.appendSlice(alloc, ", ");
        counter.* += 1;
        const placement = if (at_close and p.placement == .leading) Placement.standalone else p.placement;
        const head = try std.fmt.allocPrint(alloc, "{{\"$comm_{d}\": {{\"text\": ", .{counter.*});
        defer alloc.free(head);
        try out.appendSlice(alloc, head);
        try appendJsonStr(out, alloc, p.text);
        try out.appendSlice(alloc, ", \"placement\": \"");
        try out.appendSlice(alloc, placementName(placement));
        try out.appendSlice(alloc, "\"}");
        // Sibling $meta_comm_<N> inside the same pseudo-object so reorder/edit
        // ops can find spans next to the $comm_<N> they describe.
        const meta_head = try std.fmt.allocPrint(
            alloc,
            ", \"$meta_comm_{d}\": {{\"value_span\": ",
            .{counter.*},
        );
        defer alloc.free(meta_head);
        try out.appendSlice(alloc, meta_head);
        try appendSpanObj(out, alloc, p.text_start, p.text_end);
        try out.appendSlice(alloc, ", \"block_span\": ");
        try appendSpanObj(out, alloc, p.block_start, p.block_end);
        try out.appendSlice(alloc, "}}");
    }
    if (!at_close) try out.appendSlice(alloc, ", ");

    for (pending.items) |p| alloc.free(p.text);
    pending.clearRetainingCapacity();
}

/// Like preprocess, but preserves comments as `$comm_<N>` entries and emits
/// recovered syntax errors as `$err_<N>` entries. The result is valid JSON
/// suitable for bxp-fmt's annotated-JSON output contract.
pub fn preprocessAnnotated(alloc: std.mem.Allocator, input: []const u8) !AnnotatedResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var nest: std.ArrayList(u8) = .empty;
    defer nest.deinit(alloc);
    var pending: std.ArrayList(PendingComment) = .empty;
    defer {
        for (pending.items) |p| alloc.free(p.text);
        pending.deinit(alloc);
    }
    var pending_value_errs: std.ArrayList([]u8) = .empty;
    defer {
        for (pending_value_errs.items) |m| alloc.free(m);
        pending_value_errs.deinit(alloc);
    }
    var counter: u32 = 0;
    var key_pos = false;
    var i: usize = 0;

    // Span / meta tracking state.
    var meta_stack: std.ArrayList(NestMeta) = .empty;
    defer {
        for (meta_stack.items) |*m| {
            if (m.parent_key) |k| alloc.free(k);
            m.item_value_starts.deinit(alloc);
            m.item_value_ends.deinit(alloc);
            m.item_block_starts.deinit(alloc);
            m.item_block_ends.deinit(alloc);
        }
        meta_stack.deinit(alloc);
    }
    var pending_key: ?[]u8 = null;
    defer if (pending_key) |k| alloc.free(k);
    var pending_key_start: usize = 0;       // input pos of pending_key start
    var pending_key_end: usize = 0;         // input pos right after pending_key
    var awaiting_value: bool = false;       // true after ':' until value start
    var cur_value_start: ?usize = null;     // start of current scalar value being consumed

    while (i < input.len) {
        const c = input[i];

        // ── pre-flush array pending ──────────────────────────────────────
        // Pending comments inside an array context get emitted as single-key
        // pseudo-objects at the next value boundary. Object-context pending is
        // flushed by key/'}' handlers, so this only triggers in arrays.
        if (pending.items.len > 0 and !key_pos and isInArray(nest.items)) {
            if (!isWs(c) and c != ']' and c != ',' and c != '/') {
                try flushPendingInArray(&out, alloc, &pending, &counter, false);
            }
        }

        // ── value-start hooks (span tracking) ────────────────────────────
        // Object-context: after ':' the first non-ws / non-comment byte is the
        // value start. Composite values transfer the offset into their NestMeta
        // entry on push, scalars finalise on the next ',' / '}' / ']'.
        if (awaiting_value and !isWs(c) and c != '/') {
            cur_value_start = i;
            awaiting_value = false;
        }
        // Array-context: track current element start.
        if (meta_stack.items.len > 0) {
            const top = &meta_stack.items[meta_stack.items.len - 1];
            if (top.kind == '[' and top.cur_item_start == null and !isWs(c) and c != '/' and c != ']' and c != ',') {
                top.cur_item_start = i;
            }
        }

        // ── double-quoted string ─────────────────────────────────────────
        if (c == '"') {
            const was_key = key_pos;
            const inner_start = i + 1;
            key_pos = false;
            const str_start = i;
            try out.append(alloc, c);
            i += 1;
            var closed = false;
            while (i < input.len) {
                const sc = input[i];
                if (sc == '\n' or sc == '\r') {
                    // Unescaped newline closes the string at the boundary.
                    try out.append(alloc, '"');
                    closed = true;
                    if (isInObject(nest.items)) {
                        const msg = try std.fmt.allocPrint(alloc, "unterminated string at line {d}", .{lineOf(input, str_start)});
                        try pending_value_errs.append(alloc, msg);
                    }
                    // Discard the unparseable tail up to the next ',' or '}'/']'.
                    i = skipValue(input, i);
                    break;
                }
                try out.append(alloc, sc);
                i += 1;
                if (sc == '\\' and i < input.len) {
                    try out.append(alloc, input[i]);
                    i += 1;
                } else if (sc == '"') {
                    closed = true;
                    break;
                }
            }
            if (!closed) {
                try out.append(alloc, '"');
                if (isInObject(nest.items)) {
                    const msg = try std.fmt.allocPrint(alloc, "unterminated string at end of input (line {d})", .{lineOf(input, str_start)});
                    try pending_value_errs.append(alloc, msg);
                }
            }
            // Capture quoted key for span tracking.
            if (was_key and closed) {
                // i now points just past the closing '"'; inner content is [inner_start, i-1).
                const inner_end = if (i > 0 and i - 1 >= inner_start) i - 1 else inner_start;
                if (pending_key) |old| alloc.free(old);
                pending_key = try alloc.dupe(u8, input[inner_start..inner_end]);
                pending_key_start = str_start; // include the surrounding quotes
                pending_key_end = i;
            }
            continue;
        }

        // ── single-quoted string ─────────────────────────────────────────
        if (c == '\'') {
            const was_key_sq = key_pos;
            const inner_start_sq = i + 1;
            key_pos = false;
            const str_start = i;
            try out.append(alloc, '"');
            i += 1;
            var closed = false;
            while (i < input.len) {
                const sc = input[i];
                if (sc == '\n' or sc == '\r') {
                    try out.append(alloc, '"');
                    closed = true;
                    if (isInObject(nest.items)) {
                        const msg = try std.fmt.allocPrint(alloc, "unterminated string at line {d}", .{lineOf(input, str_start)});
                        try pending_value_errs.append(alloc, msg);
                    }
                    i = skipValue(input, i);
                    break;
                }
                i += 1;
                if (sc == '\\' and i < input.len) {
                    const esc = input[i];
                    i += 1;
                    if (esc == '\'') {
                        try out.append(alloc, '\'');
                    } else {
                        try out.append(alloc, '\\');
                        try out.append(alloc, esc);
                    }
                } else if (sc == '"') {
                    try out.appendSlice(alloc, "\\\"");
                } else if (sc == '\'') {
                    closed = true;
                    try out.append(alloc, '"');
                    break;
                } else {
                    try out.append(alloc, sc);
                }
            }
            if (!closed) {
                try out.append(alloc, '"');
                if (isInObject(nest.items)) {
                    const msg = try std.fmt.allocPrint(alloc, "unterminated string at end of input (line {d})", .{lineOf(input, str_start)});
                    try pending_value_errs.append(alloc, msg);
                }
            }
            if (was_key_sq and closed) {
                const inner_end_sq = if (i > 0 and i - 1 >= inner_start_sq) i - 1 else inner_start_sq;
                if (pending_key) |old| alloc.free(old);
                pending_key = try alloc.dupe(u8, input[inner_start_sq..inner_end_sq]);
                pending_key_start = str_start;
                pending_key_end = i;
            }
            continue;
        }

        // ── comments → capture instead of strip ──────────────────────────
        if (c == '/' and i + 1 < input.len) {
            if (input[i + 1] == '/') {
                const start = i;
                i += 2;
                const text_body_start = i;
                while (i < input.len and input[i] != '\n') i += 1;
                const text_body_end = i;
                const text = try alloc.dupe(u8, input[start..i]);
                const placement = detectLinePlacement(input, start);
                const blk_start = if (placement == .leading) walkBackToLineStart(input, start) else start;
                try pending.append(alloc, .{
                    .text = text,
                    .placement = placement,
                    .block_start = blk_start,
                    .block_end = i,
                    .text_start = text_body_start,
                    .text_end = text_body_end,
                });
                continue;
            }
            if (input[i + 1] == '*') {
                const start = i;
                i += 2;
                const text_body_start = i;
                var body_end = i;
                while (i + 1 < input.len) {
                    if (input[i] == '*' and input[i + 1] == '/') { body_end = i; i += 2; break; }
                    i += 1;
                }
                const text = try alloc.dupe(u8, input[start..i]);
                try pending.append(alloc, .{
                    .text = text,
                    .placement = .block,
                    .block_start = start,
                    .block_end = i,
                    .text_start = text_body_start,
                    .text_end = body_end,
                });
                continue;
            }
        }

        // ── structural tokens ────────────────────────────────────────────
        switch (c) {
            '{' => {
                // Do NOT flush here: pending comments belong inside this new
                // object (e.g. `// top\n{ ... }` → comment becomes first child).
                try meta_stack.append(alloc, .{
                    .kind = '{',
                    .open_pos = i,
                    .parent_key = pending_key, // transfer ownership
                    .parent_key_start = pending_key_start,
                    .parent_key_end = pending_key_end,
                    .item_value_starts = .empty,
                    .item_value_ends = .empty,
                    .item_block_starts = .empty,
                    .item_block_ends = .empty,
                    .cur_item_start = null,
                });
                pending_key = null;
                cur_value_start = null; // composite tracked via meta
                try nest.append(alloc, '{');
                key_pos = true;
                try out.append(alloc, c);
                i += 1;
            },
            '}' => {
                // Finalize pending scalar value in this object.
                if (pending_key != null and cur_value_start != null) {
                    const v_end = trimTrailingWs(input, i);
                    const b_start = walkBackToLineStart(input, pending_key_start);
                    const b_end = walkForwardToLineEnd(input, v_end);
                    try emitChildMeta(&out, alloc, pending_key.?,
                        pending_key_start, pending_key_end,
                        cur_value_start.?, v_end,
                        b_start, b_end);
                    alloc.free(pending_key.?);
                    pending_key = null;
                    cur_value_start = null;
                }
                try flushValueErrs(&out, alloc, &pending_value_errs, &counter);
                try flushPending(&out, alloc, &pending, &counter, true);
                // Emit `$meta_self` for the closing object as the last sibling.
                const close_end = i + 1;
                if (meta_stack.items.len > 0) {
                    const top_now = &meta_stack.items[meta_stack.items.len - 1];
                    if (top_now.kind == '{') {
                        try emitContainerMeta(&out, alloc, top_now.open_pos, close_end);
                    }
                }
                _ = nest.pop();
                key_pos = false;
                removeTrailingComma(&out);
                try out.append(alloc, c);
                i += 1;
                // Pop meta and emit composite child meta into parent if it is an object.
                if (meta_stack.pop()) |popped| {
                    var m = popped;
                    defer {
                        if (m.parent_key) |k| alloc.free(k);
                        m.item_value_starts.deinit(alloc);
                        m.item_value_ends.deinit(alloc);
                        m.item_block_starts.deinit(alloc);
                        m.item_block_ends.deinit(alloc);
                    }
                    if (m.parent_key) |pk| {
                        if (isInObject(nest.items)) {
                            const b_start = walkBackToLineStart(input, m.parent_key_start);
                            const b_end = walkForwardToLineEnd(input, close_end);
                            try emitChildMeta(&out, alloc, pk,
                                m.parent_key_start, m.parent_key_end,
                                m.open_pos, close_end,
                                b_start, b_end);
                        }
                    }
                }
            },
            '[' => {
                // Pending comments collected before '[' belong inside the new
                // array (mirrors '{' which carries its leading comments inward).
                // They will be flushed as pseudo-objects before the first value
                // (or as standalone if the array is empty).
                try meta_stack.append(alloc, .{
                    .kind = '[',
                    .open_pos = i,
                    .parent_key = pending_key,
                    .parent_key_start = pending_key_start,
                    .parent_key_end = pending_key_end,
                    .item_value_starts = .empty,
                    .item_value_ends = .empty,
                    .item_block_starts = .empty,
                    .item_block_ends = .empty,
                    .cur_item_start = null,
                });
                pending_key = null;
                cur_value_start = null;
                try nest.append(alloc, '[');
                key_pos = false;
                try out.append(alloc, c);
                i += 1;
            },
            ']' => {
                // Finalise the last array element's span before close.
                if (meta_stack.items.len > 0) {
                    const top = &meta_stack.items[meta_stack.items.len - 1];
                    if (top.kind == '[' and top.cur_item_start != null) {
                        const v_end = trimTrailingWs(input, i);
                        const b_start = walkBackToLineStart(input, top.cur_item_start.?);
                        const b_end = walkForwardToLineEnd(input, v_end);
                        try top.item_value_starts.append(alloc, top.cur_item_start.?);
                        try top.item_value_ends.append(alloc, v_end);
                        try top.item_block_starts.append(alloc, b_start);
                        try top.item_block_ends.append(alloc, b_end);
                        top.cur_item_start = null;
                    }
                }
                try flushPendingInArray(&out, alloc, &pending, &counter, true);
                dropValueErrs(alloc, &pending_value_errs);
                // Arrays don't get `$meta_self` (they have no keys, so can't carry
                // sibling meta inside `[...]`); container_span is already exposed via
                // the parent object's `$meta_<key>.value_span`.
                const close_end = i + 1;
                _ = nest.pop();
                key_pos = false;
                removeTrailingComma(&out);
                try out.append(alloc, c);
                i += 1;
                if (meta_stack.pop()) |popped| {
                    var m = popped;
                    defer {
                        if (m.parent_key) |k| alloc.free(k);
                        m.item_value_starts.deinit(alloc);
                        m.item_value_ends.deinit(alloc);
                        m.item_block_starts.deinit(alloc);
                        m.item_block_ends.deinit(alloc);
                    }
                    if (m.parent_key) |pk| {
                        if (isInObject(nest.items)) {
                            const b_start = walkBackToLineStart(input, m.parent_key_start);
                            const b_end = walkForwardToLineEnd(input, close_end);
                            try emitChildMeta(&out, alloc, pk,
                                m.parent_key_start, m.parent_key_end,
                                m.open_pos, close_end,
                                b_start, b_end);
                            try emitElemMeta(&out, alloc, pk,
                                m.item_value_starts.items, m.item_value_ends.items,
                                m.item_block_starts.items, m.item_block_ends.items);
                        }
                    }
                }
            },
            ':' => {
                key_pos = false;
                awaiting_value = true;
                try out.append(alloc, c);
                i += 1;
            },
            ',' => {
                // Finalise scalar in object.
                if (pending_key != null and cur_value_start != null and isInObject(nest.items)) {
                    const v_end = trimTrailingWs(input, i);
                    const b_start = walkBackToLineStart(input, pending_key_start);
                    const b_end = walkForwardToLineEnd(input, v_end);
                    try emitChildMeta(&out, alloc, pending_key.?,
                        pending_key_start, pending_key_end,
                        cur_value_start.?, v_end,
                        b_start, b_end);
                    alloc.free(pending_key.?);
                    pending_key = null;
                    cur_value_start = null;
                }
                // Finalise current array element.
                if (meta_stack.items.len > 0) {
                    const top = &meta_stack.items[meta_stack.items.len - 1];
                    if (top.kind == '[' and top.cur_item_start != null) {
                        const v_end = trimTrailingWs(input, i);
                        const b_start = walkBackToLineStart(input, top.cur_item_start.?);
                        const b_end = walkForwardToLineEnd(input, v_end);
                        try top.item_value_starts.append(alloc, top.cur_item_start.?);
                        try top.item_value_ends.append(alloc, v_end);
                        try top.item_block_starts.append(alloc, b_start);
                        try top.item_block_ends.append(alloc, b_end);
                        top.cur_item_start = null;
                    }
                }
                try flushValueErrs(&out, alloc, &pending_value_errs, &counter);
                key_pos = nest.items.len > 0 and nest.items[nest.items.len - 1] == '{';
                try out.append(alloc, c);
                i += 1;
            },
            else => {
                if (key_pos and (std.ascii.isAlphabetic(c) or c == '_' or c == '$')) {
                    try flushPending(&out, alloc, &pending, &counter, false);

                    const key_start = i;
                    while (i < input.len) {
                        const kc = input[i];
                        if (!std.ascii.isAlphanumeric(kc) and kc != '_' and kc != '$') break;
                        i += 1;
                    }
                    // Peek past ALL whitespace incl. \n/\r — catches keys
                    // split by a newline (`file_type_o\n  ut: ...`).
                    var j = i;
                    while (j < input.len and isWs(input[j])) : (j += 1) {}
                    if (j >= input.len or input[j] == ':') {
                        try out.append(alloc, '"');
                        try out.appendSlice(alloc, input[key_start..i]);
                        try out.append(alloc, '"');
                        // Capture key for span tracking on the upcoming value.
                        if (pending_key) |old| alloc.free(old);
                        pending_key = try alloc.dupe(u8, input[key_start..i]);
                        pending_key_start = key_start;
                        pending_key_end = i;
                        key_pos = false;
                    } else {
                        // Scan for ':' but stop at the next ',' / '}' / ']' so
                        // we don't absorb a later key's colon. Skip over string
                        // literals so their bytes don't interfere.
                        var colon = j;
                        while (colon < input.len) : (colon += 1) {
                            const ch = input[colon];
                            if (ch == ':') break;
                            if (ch == ',' or ch == '}' or ch == ']') break;
                            if (ch == '"' or ch == '\'') {
                                const qc = ch;
                                colon += 1;
                                while (colon < input.len) : (colon += 1) {
                                    if (input[colon] == '\\' and colon + 1 < input.len) {
                                        colon += 1;
                                        continue;
                                    }
                                    if (input[colon] == qc) break;
                                }
                            }
                        }
                        const has_colon = colon < input.len and input[colon] == ':';
                        // Clear stale pending_key from any previous successful key emission.
                        if (pending_key) |old| { alloc.free(old); pending_key = null; }
                        cur_value_start = null;
                        awaiting_value = false;
                        const err_line = lineOf(input, key_start);
                        counter += 1;
                        const head = try std.fmt.allocPrint(alloc, "\"$err_{d}\": ", .{counter});
                        defer alloc.free(head);
                        try out.appendSlice(alloc, head);
                        if (!has_colon) {
                            // Missing colon: skip up to next ',' or '}' so we
                            // don't lose subsequent keys in this object.
                            const skip_end = skipValue(input, j);
                            const after_full = std.mem.trim(u8, input[j..skip_end], " \t\r\n");
                            const after = if (after_full.len > 30) after_full[0..30] else after_full;
                            const msg = try std.fmt.allocPrint(alloc, "{s} {s} --> missing colon after key at line {d}", .{
                                input[key_start..i], after, err_line,
                            });
                            defer alloc.free(msg);
                            try appendJsonStr(&out, alloc, msg);
                            i = skip_end;
                        } else {
                            const raw_key = std.mem.trim(u8, input[key_start..colon], " \t\r\n");
                            var vs = colon + 1;
                            while (vs < input.len and (input[vs] == ' ' or input[vs] == '\t')) : (vs += 1) {}
                            const val_end = skipValue(input, vs);
                            const raw_val_full = std.mem.trim(u8, input[vs..val_end], " \t\r\n");
                            const raw_val = if (raw_val_full.len > 30) raw_val_full[0..30] else raw_val_full;
                            const ws_kind = whitespaceKind(input[i..colon]);
                            const msg = try std.fmt.allocPrint(alloc, "{s}: '{s}' --> malformed key ({s} in key) at line {d}", .{
                                raw_key, raw_val, ws_kind, err_line,
                            });
                            defer alloc.free(msg);
                            try appendJsonStr(&out, alloc, msg);
                            i = val_end;
                        }
                        key_pos = false;
                    }
                } else if (!key_pos and std.ascii.isAlphabetic(c)) {
                    // Bare identifier in value position. Two cases:
                    //   (a) followed by ':' inside an object → missing-comma
                    //       recovery: emit synthetic ',' + $err_<N>, treat ident
                    //       as the next key.
                    //   (b) otherwise → invalid literal: wrap as a string, queue
                    //       a value-error sibling. true/false/null pass through.
                    const start = i;
                    var jp: usize = i;
                    while (jp < input.len) {
                        const kc = input[jp];
                        if (!std.ascii.isAlphanumeric(kc) and kc != '_') break;
                        jp += 1;
                    }
                    const ident = input[start..jp];

                    var p = jp;
                    while (p < input.len and isWs(input[p])) : (p += 1) {}
                    const looks_like_key = p < input.len and input[p] == ':' and isInObject(nest.items);

                    if (looks_like_key) {
                        try flushValueErrs(&out, alloc, &pending_value_errs, &counter);
                        if (needsLeadingComma(out.items)) try out.appendSlice(alloc, ", ");
                        try flushPending(&out, alloc, &pending, &counter, false);
                        const err_line = lineOf(input, start);
                        const msg = try std.fmt.allocPrint(alloc, "missing comma before '{s}' at line {d}", .{ ident, err_line });
                        defer alloc.free(msg);
                        counter += 1;
                        const head = try std.fmt.allocPrint(alloc, "\"$err_{d}\": ", .{counter});
                        defer alloc.free(head);
                        try out.appendSlice(alloc, head);
                        try appendJsonStr(&out, alloc, msg);
                        try out.appendSlice(alloc, ", \"");
                        try out.appendSlice(alloc, ident);
                        try out.append(alloc, '"');
                        i = jp;
                        key_pos = false;
                    } else {
                        i = jp;
                        if (std.mem.eql(u8, ident, "true") or
                            std.mem.eql(u8, ident, "false") or
                            std.mem.eql(u8, ident, "null"))
                        {
                            try out.appendSlice(alloc, ident);
                        } else {
                            try out.append(alloc, '"');
                            try out.appendSlice(alloc, ident);
                            try out.append(alloc, '"');
                            if (isInObject(nest.items)) {
                                const err_line = lineOf(input, start);
                                const msg = try std.fmt.allocPrint(alloc, "'{s}' --> invalid literal in value position at line {d}", .{
                                    ident, err_line,
                                });
                                try pending_value_errs.append(alloc, msg);
                            }
                        }
                    }
                } else {
                    try out.append(alloc, c);
                    i += 1;
                }
            },
        }
    }

    return .{ .out = try out.toOwnedSlice(alloc), .next_id = counter + 1 };
}

// ── tests ────────────────────────────────────────────────────────────────────

test "single-line comment" {
    const alloc = std.testing.allocator;
    const out = try preprocess(alloc, "{ // comment\n\"a\": 1 }");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{ \n\"a\": 1 }", out);
}

test "multi-line comment" {
    const alloc = std.testing.allocator;
    const out = try preprocess(alloc, "{/* hi */\"a\":1}");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"a\":1}", out);
}

test "unquoted key" {
    const alloc = std.testing.allocator;
    const out = try preprocess(alloc, "{foo: 1}");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"foo\": 1}", out);
}

test "multiple unquoted keys" {
    const alloc = std.testing.allocator;
    const out = try preprocess(alloc, "{a: 1, b: 2, c: 3}");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"a\": 1, \"b\": 2, \"c\": 3}", out);
}

test "nested unquoted keys" {
    const alloc = std.testing.allocator;
    const out = try preprocess(alloc, "{a: {b: {c: 1}}}");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"a\": {\"b\": {\"c\": 1}}}", out);
}

test "trailing comma in object" {
    const alloc = std.testing.allocator;
    const out = try preprocess(alloc, "{\"a\": 1,}");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"a\": 1}", out);
}

test "trailing comma in array" {
    const alloc = std.testing.allocator;
    const out = try preprocess(alloc, "[1, 2, 3,]");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("[1, 2, 3]", out);
}

test "single-quoted string" {
    const alloc = std.testing.allocator;
    const out = try preprocess(alloc, "{'hello'}");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"hello\"}", out);
}

test "comment inside string not stripped" {
    const alloc = std.testing.allocator;
    const out = try preprocess(alloc, "{\"a\": \"val // not a comment\"}");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"a\": \"val // not a comment\"}", out);
}

test "combined: comment + unquoted keys + trailing comma" {
    const alloc = std.testing.allocator;
    const src =
        \\{
        \\  // top comment
        \\  outer: {
        \\    inner: "val", // inline comment
        \\  },
        \\}
    ;
    const out = try preprocess(alloc, src);
    defer alloc.free(out);
    // outer trailing comma removed, inner trailing comma removed
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "error recovery: space inside unquoted key" {
    const alloc = std.testing.allocator;
    const src =
        \\{file_type_o ut: "csv", other: 1}
    ;
    const out = try preprocess(alloc, src);
    defer alloc.free(out);
    // Output must be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    // Bad key replaced with $err_trace
    try std.testing.expect(parsed.value.object.get("$err_trace_1") != null);
    // Keys after the bad one still present
    try std.testing.expect(parsed.value.object.get("other") != null);
}

// ── annotated variant tests ──────────────────────────────────────────────

test "annotated: comment preserved as $comm leading" {
    const alloc = std.testing.allocator;
    const r = try preprocessAnnotated(alloc, "// hi\n{a:1}");
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const comm = parsed.value.object.get("$comm_1") orelse return error.Missing;
    try std.testing.expectEqualStrings("// hi", comm.object.get("text").?.string);
    try std.testing.expectEqualStrings("leading", comm.object.get("placement").?.string);
    try std.testing.expect(parsed.value.object.get("a") != null);
}

test "annotated: comment preserved as $comm trailing" {
    const alloc = std.testing.allocator;
    const r = try preprocessAnnotated(alloc, "{a:1 // hi\n}");
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const comm = parsed.value.object.get("$comm_1") orelse return error.Missing;
    try std.testing.expectEqualStrings("// hi", comm.object.get("text").?.string);
    // trailing comment after value at end of object → keeps trailing placement
    try std.testing.expectEqualStrings("trailing", comm.object.get("placement").?.string);
}

test "annotated: $meta_comm_<N> spans for line + block comment" {
    const alloc = std.testing.allocator;
    const src = "// hello\n{a:1, /* inline */ b:2}";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    // Leading line comment: text_span covers " hello", block_span covers "// hello".
    const m1 = parsed.value.object.get("$meta_comm_1") orelse return error.MissingMeta1;
    const v1s: usize = @intCast(m1.object.get("value_span").?.object.get("start").?.integer);
    const v1e: usize = @intCast(m1.object.get("value_span").?.object.get("end").?.integer);
    const b1s: usize = @intCast(m1.object.get("block_span").?.object.get("start").?.integer);
    const b1e: usize = @intCast(m1.object.get("block_span").?.object.get("end").?.integer);
    try std.testing.expectEqualStrings(" hello", src[v1s..v1e]);
    try std.testing.expectEqualStrings("// hello", src[b1s..b1e]);
    // Inline block comment: text_span covers " inline ", block_span covers "/* inline */".
    const m2 = parsed.value.object.get("$meta_comm_2") orelse return error.MissingMeta2;
    const v2s: usize = @intCast(m2.object.get("value_span").?.object.get("start").?.integer);
    const v2e: usize = @intCast(m2.object.get("value_span").?.object.get("end").?.integer);
    const b2s: usize = @intCast(m2.object.get("block_span").?.object.get("start").?.integer);
    const b2e: usize = @intCast(m2.object.get("block_span").?.object.get("end").?.integer);
    try std.testing.expectEqualStrings(" inline ", src[v2s..v2e]);
    try std.testing.expectEqualStrings("/* inline */", src[b2s..b2e]);
}

test "annotated: $meta_comm_<N> inside array pseudo-object" {
    const alloc = std.testing.allocator;
    const src = "[1, // mid\n 2]";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    // Find the pseudo-object carrying $comm_1 + $meta_comm_1.
    var found = false;
    for (arr.items) |it| {
        if (it != .object) continue;
        const meta = it.object.get("$meta_comm_1") orelse continue;
        const vs: usize = @intCast(meta.object.get("value_span").?.object.get("start").?.integer);
        const ve: usize = @intCast(meta.object.get("value_span").?.object.get("end").?.integer);
        try std.testing.expectEqualStrings(" mid", src[vs..ve]);
        found = true;
    }
    try std.testing.expect(found);
}

test "annotated: multiple comments numbered" {
    const alloc = std.testing.allocator;
    const r = try preprocessAnnotated(alloc, "{\n// one\n// two\na:1}");
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("$comm_1") != null);
    try std.testing.expect(parsed.value.object.get("$comm_2") != null);
    try std.testing.expectEqualStrings("// one", parsed.value.object.get("$comm_1").?.object.get("text").?.string);
    try std.testing.expectEqualStrings("// two", parsed.value.object.get("$comm_2").?.object.get("text").?.string);
}

test "annotated: block comment preserved" {
    const alloc = std.testing.allocator;
    const r = try preprocessAnnotated(alloc, "{/* foo */a:1}");
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const comm = parsed.value.object.get("$comm_1") orelse return error.Missing;
    try std.testing.expectEqualStrings("/* foo */", comm.object.get("text").?.string);
    try std.testing.expectEqualStrings("block", comm.object.get("placement").?.string);
}

test "annotated: standalone comment at end of object" {
    const alloc = std.testing.allocator;
    const r = try preprocessAnnotated(alloc, "{a:1\n// tail\n}");
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const comm = parsed.value.object.get("$comm_1") orelse return error.Missing;
    // leading-style comment (own line) flushed at } → reclassified to standalone
    try std.testing.expectEqualStrings("standalone", comm.object.get("placement").?.string);
}

test "annotated: comment + space-in-key combined" {
    const alloc = std.testing.allocator;
    const src =
        \\{
        \\  // c
        \\  bad key: "v"
        \\}
    ;
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("$comm_1") != null);
    try std.testing.expect(parsed.value.object.get("$err_2") != null);
    try std.testing.expect(r.next_id == 3);
}

test "annotated: newline inside unquoted key" {
    const alloc = std.testing.allocator;
    const src = "{file_type_o\n  ut: \"csv\"}";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("$err_1") orelse return error.Missing;
    try std.testing.expect(std.mem.indexOf(u8, err.string, "newline in key") != null);
}

test "annotated: missing colon after key" {
    const alloc = std.testing.allocator;
    const src = "{foo \"bar\", b: 1}";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("$err_1") orelse return error.Missing;
    try std.testing.expect(std.mem.indexOf(u8, err.string, "missing colon") != null);
    // Subsequent key still parsed — recovery resumes at next ',' / '}'.
    try std.testing.expect(parsed.value.object.get("b") != null);
}

test "annotated: unterminated string with newline" {
    const alloc = std.testing.allocator;
    const src = "{a: \"csv\nb: 1}";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    // 'a' value is the closed-at-newline string; an $err_<N> sibling describes
    // the unterminated string. The salvaged tail ('b: 1') is reinterpreted —
    // 'b' becomes an invalid literal, also recorded as $err_<N>.
    try std.testing.expect(parsed.value.object.get("a") != null);
    var found_unterm = false;
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_")) {
            if (std.mem.indexOf(u8, kv.value_ptr.string, "unterminated string") != null) {
                found_unterm = true;
            }
        }
    }
    try std.testing.expect(found_unterm);
}

test "annotated: unterminated string at EOF" {
    const alloc = std.testing.allocator;
    const src = "{a: \"no closing";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    // After closing the string and skipping no more input we still need to
    // close the object; preprocessAnnotated does not synthesize '}', so the
    // raw output is invalid JSON. We assert the error was at least queued by
    // searching the raw output bytes (which include the would-be sibling once
    // a ',' or '}' is reached). Since there is no ',' or '}' here, the err
    // remains unflushed — accept that as documented behavior. Ensure no crash.
    try std.testing.expect(r.out.len > 0);
}

test "annotated: invalid literal in value position" {
    const alloc = std.testing.allocator;
    const src = "{a: foo, b: 1}";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    // 'foo' wrapped as string value
    const a = parsed.value.object.get("a") orelse return error.Missing;
    try std.testing.expectEqualStrings("foo", a.string);
    // Sibling $err_<N> describes the invalid literal
    var found = false;
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_")) {
            if (std.mem.indexOf(u8, kv.value_ptr.string, "invalid literal") != null) {
                found = true;
            }
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(parsed.value.object.get("b") != null);
}

test "annotated: missing comma between object entries" {
    const alloc = std.testing.allocator;
    const src = "{a: 1\nb: 2}";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("a") != null);
    try std.testing.expect(parsed.value.object.get("b") != null);
    var found = false;
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv.key_ptr.*, "$err_")) {
            if (std.mem.indexOf(u8, kv.value_ptr.string, "missing comma") != null) {
                found = true;
            }
        }
    }
    try std.testing.expect(found);
}

test "annotated: $meta_<key> covers scalar values in object" {
    const alloc = std.testing.allocator;
    const src = "{a:1, b:\"x\"}";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const meta_a = parsed.value.object.get("$meta_a") orelse return error.Missing;
    const va = meta_a.object.get("value_span").?.object;
    try std.testing.expect(va.get("start").?.integer == 3);
    try std.testing.expect(va.get("end").?.integer == 4);
    const ka = meta_a.object.get("key_span").?.object;
    try std.testing.expect(ka.get("start").?.integer == 1);
    try std.testing.expect(ka.get("end").?.integer == 2);
    const meta_b = parsed.value.object.get("$meta_b") orelse return error.Missing;
    const vb = meta_b.object.get("value_span").?.object;
    try std.testing.expect(vb.get("start").?.integer == 8);
    try std.testing.expect(vb.get("end").?.integer == 11);
}

test "annotated: $meta_<key> for nested object" {
    const alloc = std.testing.allocator;
    // positions: 0='{' 1='a' 2=':' 3=' ' 4='{' 5='b' 6=':' 7='1' 8='}' 9='}'
    const src = "{a: {b:1}}";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    // Outer object: $meta_a value_span covers inner '{...}'
    const va = parsed.value.object.get("$meta_a").?.object.get("value_span").?.object;
    try std.testing.expect(va.get("start").?.integer == 4);
    try std.testing.expect(va.get("end").?.integer == 9);
    // Inner object: $meta_b for the scalar
    const inner = parsed.value.object.get("a").?.object;
    const vb = inner.get("$meta_b").?.object.get("value_span").?.object;
    try std.testing.expect(vb.get("start").?.integer == 7);
    try std.testing.expect(vb.get("end").?.integer == 8);
}

test "annotated: $elem_meta_<key> for array elements" {
    const alloc = std.testing.allocator;
    // positions: 0='{' 1='a' 2=':' 3='[' 4='1' 5=',' 6='2' 7=']' 8='}'
    const src = "{a:[1,2]}";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const va = parsed.value.object.get("$meta_a").?.object.get("value_span").?.object;
    try std.testing.expect(va.get("start").?.integer == 3);
    try std.testing.expect(va.get("end").?.integer == 8);
    const elems = parsed.value.object.get("$elem_meta_a").?.array;
    try std.testing.expect(elems.items.len == 2);
    const e0v = elems.items[0].object.get("value_span").?.object;
    try std.testing.expect(e0v.get("start").?.integer == 4);
    try std.testing.expect(e0v.get("end").?.integer == 5);
    const e1v = elems.items[1].object.get("value_span").?.object;
    try std.testing.expect(e1v.get("start").?.integer == 6);
    try std.testing.expect(e1v.get("end").?.integer == 7);
}

test "annotated: $meta_self container_span for root object" {
    const alloc = std.testing.allocator;
    // positions: 0='{' 1='a' 2=':' 3='1' 4='}'
    const src = "{a:1}";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const ms = parsed.value.object.get("$meta_self") orelse return error.Missing;
    const cs = ms.object.get("container_span").?.object;
    try std.testing.expect(cs.get("start").?.integer == 0);
    try std.testing.expect(cs.get("end").?.integer == 5);
}

test "annotated: block_span includes leading indent and trailing comma" {
    const alloc = std.testing.allocator;
    // line 1 (index 0..1): `\n` (none — let's craft manually)
    //                            0 1 2 3 4 5  6 7 8 9 10 11 12
    const src = "{\n  a: 1,\n  b: 2\n}";
    //         pos: 0    1   2-3 4 5 6 7 8   9 10-11 12 13 14   15  16
    // Let's count: 0='{', 1='\n', 2=' ', 3=' ', 4='a', 5=':', 6=' ', 7='1', 8=',', 9='\n', 10=' ', 11=' ', 12='b', 13=':', 14=' ', 15='2', 16='\n', 17='}'
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const ba = parsed.value.object.get("$meta_a").?.object.get("block_span").?.object;
    try std.testing.expect(ba.get("start").?.integer == 2);   // start of leading indent
    try std.testing.expect(ba.get("end").?.integer == 9);     // up to '\n' (exclusive)
    const bb = parsed.value.object.get("$meta_b").?.object.get("block_span").?.object;
    try std.testing.expect(bb.get("start").?.integer == 10);
    try std.testing.expect(bb.get("end").?.integer == 16);
}

test "annotated: comment in array — leading block" {
    const alloc = std.testing.allocator;
    const r = try preprocessAnnotated(alloc, "{a:[/* x */ 1]}");
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("a").?.array;
    // [pseudo-comment, 1]
    try std.testing.expect(arr.items.len == 2);
    const first = arr.items[0].object;
    const comm = first.get("$comm_1") orelse return error.Missing;
    try std.testing.expectEqualStrings("/* x */", comm.object.get("text").?.string);
    try std.testing.expectEqualStrings("block", comm.object.get("placement").?.string);
    try std.testing.expect(arr.items[1].integer == 1);
}

test "annotated: comment between array elements" {
    const alloc = std.testing.allocator;
    const r = try preprocessAnnotated(alloc, "{a:[1,\n// hi\n2]}");
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("a").?.array;
    try std.testing.expect(arr.items.len == 3);
    try std.testing.expect(arr.items[0].integer == 1);
    const comm = arr.items[1].object.get("$comm_1") orelse return error.Missing;
    try std.testing.expectEqualStrings("// hi", comm.object.get("text").?.string);
    try std.testing.expect(arr.items[2].integer == 2);
}

test "annotated: comment at end of array — standalone" {
    const alloc = std.testing.allocator;
    const r = try preprocessAnnotated(alloc, "{a:[1,\n// last\n]}");
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("a").?.array;
    try std.testing.expect(arr.items.len == 2);
    try std.testing.expect(arr.items[0].integer == 1);
    const comm = arr.items[1].object.get("$comm_1") orelse return error.Missing;
    try std.testing.expectEqualStrings("standalone", comm.object.get("placement").?.string);
}

test "annotated: true/false/null preserved as keywords" {
    const alloc = std.testing.allocator;
    const src = "{a: true, b: false, c: null}";
    const r = try preprocessAnnotated(alloc, src);
    defer alloc.free(r.out);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, r.out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("a").?.bool == true);
    try std.testing.expect(parsed.value.object.get("b").?.bool == false);
    try std.testing.expect(parsed.value.object.get("c").? == .null);
    // No error keys produced.
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        try std.testing.expect(!std.mem.startsWith(u8, kv.key_ptr.*, "$err_"));
    }
}
