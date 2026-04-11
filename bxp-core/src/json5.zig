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
                    const start = i;
                    while (i < input.len) {
                        const kc = input[i];
                        if (!std.ascii.isAlphanumeric(kc) and kc != '_' and kc != '$') break;
                        i += 1;
                    }
                    try out.append(alloc, '"');
                    try out.appendSlice(alloc, input[start..i]);
                    try out.append(alloc, '"');
                    key_pos = false;
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
