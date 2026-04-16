const std = @import("std");
const dvui = @import("dvui");

pub const TokenKind = enum {
    string_lit,
    triple_quote,
    number_lit,
    ident,
    field_ref,
    operator,
    whitespace,
    err,
};

pub const Span = struct {
    start: usize,
    end: usize,
    kind: TokenKind,
};

/// Dracula-inspired token colors.
pub fn colorFor(kind: TokenKind) dvui.Color {
    return switch (kind) {
        .string_lit => .fromHex("#f1fa8c"), // yellow
        .triple_quote => .fromHex("#f1fa8c"),
        .number_lit => .fromHex("#bd93f9"), // purple
        .ident => .fromHex("#50fa7b"), // green (functions/keywords)
        .field_ref => .fromHex("#8be9fd"), // cyan
        .operator => .fromHex("#ff79c6"), // pink
        .whitespace => .fromHex("#f8f8f2"),
        .err => .fromHex("#ff5555"), // red
    };
}

/// Tokenize `src` into spans. Caller owns the returned slice (arena-allocated).
pub fn tokenize(arena: std.mem.Allocator, src: []const u8) []const Span {
    var spans = std.ArrayListUnmanaged(Span){};
    _ = &spans;
    var pos: usize = 0;

    while (pos < src.len) {
        const c = src[pos];

        if (c == ' ') {
            const start = pos;
            while (pos < src.len and src[pos] == ' ') pos += 1;
            spans.append(arena,.{ .start = start, .end = pos, .kind = .whitespace }) catch return spans.items;
            continue;
        }

        if (c == '\'') {
            const start = pos;
            pos += 1;
            if (pos + 1 < src.len and src[pos] == '\'' and src[pos + 1] == '\'') {
                pos += 2;
                spans.append(arena,.{ .start = start, .end = pos, .kind = .triple_quote }) catch return spans.items;
                continue;
            }
            while (pos < src.len and src[pos] != '\'') pos += 1;
            if (pos < src.len) pos += 1;
            spans.append(arena,.{ .start = start, .end = pos, .kind = .string_lit }) catch return spans.items;
            continue;
        }

        if (c == '[') {
            const start = pos;
            pos += 1;
            while (pos < src.len and src[pos] != ']') pos += 1;
            if (pos < src.len) pos += 1;
            spans.append(arena,.{ .start = start, .end = pos, .kind = .field_ref }) catch return spans.items;
            continue;
        }

        if (std.ascii.isDigit(c) or (c == '-' and pos + 1 < src.len and std.ascii.isDigit(src[pos + 1]))) {
            const start = pos;
            if (c == '-') pos += 1;
            while (pos < src.len and (std.ascii.isDigit(src[pos]) or src[pos] == '.')) pos += 1;
            spans.append(arena,.{ .start = start, .end = pos, .kind = .number_lit }) catch return spans.items;
            continue;
        }

        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = pos;
            while (pos < src.len and (std.ascii.isAlphanumeric(src[pos]) or src[pos] == '_')) pos += 1;
            spans.append(arena,.{ .start = start, .end = pos, .kind = .ident }) catch return spans.items;
            continue;
        }

        const start = pos;
        pos += 1;
        if ((c == '!' or c == '<' or c == '>') and pos < src.len and src[pos] == '=') pos += 1;
        const kind: TokenKind = switch (c) {
            '(', ')', ',', '+', '-', '*', '/', '&', '=', '!', '<', '>' => .operator,
            else => .err,
        };
        spans.append(arena,.{ .start = start, .end = pos, .kind = kind }) catch return spans.items;
    }

    return spans.items;
}

/// Render `expr_text` into a TextLayout with per-token coloring.
pub fn addHighlighted(tl: anytype, expr_text: []const u8) void {
    const arena = dvui.currentWindow().arena();
    const spans = tokenize(arena, expr_text);
    if (spans.len == 0) return;

    for (spans) |span| {
        const text = expr_text[span.start..span.end];
        tl.*.addText(text, .{ .color_text = colorFor(span.kind) });
    }
}
