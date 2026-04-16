const std = @import("std");
const dvui = @import("dvui");
const autocomplete = @import("autocomplete.zig");

pub const Result = struct {
    text_changed: bool,
    text: []const u8,
};

/// Expression text-entry with builtin-function autocomplete.
///
/// Wraps a TextEntry and a SuggestionWidget. When the trailing word at
/// the end of the buffer matches a prefix of any known builtin (case-
/// insensitive uppercase comparison), a floating menu appears below the
/// entry. Picking an entry replaces that trailing prefix with the
/// suggestion's `insert` text via `textSet`.
///
/// Buffer is owned by the caller (fixed-size byte array, null-terminated
/// trailing zeros). Returns the entry's `text_changed` flag and the
/// current text slice — read it before the next call to `exprEntry`.
pub fn exprEntry(
    src: std.builtin.SourceLocation,
    buf: []u8,
    opts: dvui.Options,
) Result {
    const te = dvui.widgetAlloc(dvui.TextEntryWidget);
    te.init(src, .{ .text = .{ .buffer = buf } }, opts);
    var sug = dvui.suggestion(te, .{
        .open_on_focus = false,
        .open_on_text_change = true,
    });

    const text_now = te.getText();
    const tail = trailingIdent(text_now);

    var matches: [autocomplete.builtins.len]autocomplete.Suggestion = undefined;
    const n_matches = if (tail.len > 0)
        autocomplete.matchBuiltins(tail, &matches)
    else
        0;

    if (n_matches > 0 and sug.dropped()) {
        for (matches[0..n_matches]) |m| {
            if (sug.addChoiceLabel(m.detail)) {
                const keep_len = text_now.len - tail.len;
                var combined: [1024]u8 = undefined;
                if (keep_len + m.insert.len <= combined.len) {
                    @memcpy(combined[0..keep_len], text_now[0..keep_len]);
                    @memcpy(combined[keep_len .. keep_len + m.insert.len], m.insert);
                    te.textSet(combined[0 .. keep_len + m.insert.len], false);
                }
            }
        }
    }

    te.draw();
    const result: Result = .{ .text_changed = te.text_changed, .text = te.getText() };

    sug.deinit();
    te.deinit();
    return result;
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn trailingIdent(text: []const u8) []const u8 {
    var start: usize = text.len;
    while (start > 0 and isIdentByte(text[start - 1])) : (start -= 1) {}
    if (start == text.len) return "";
    if (!std.ascii.isUpper(text[start])) return "";
    return text[start..];
}
