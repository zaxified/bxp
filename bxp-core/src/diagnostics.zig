/// Structured diagnostics for config / json5 / expr validation.
///
/// Used by bxp-fmt's `--config` deep validation pass to collect every
/// error / warning / info finding with a JSON-tree path, optional
/// source line/col, optional in-expression byte offset, machine-readable
/// code, and optional did-you-mean suggestion. bxp-cli passes a null
/// sink — the existing fail-fast / stderr behavior is preserved bit by
/// bit.
///
/// Severity routing (in bxp-fmt's annotated JSON output, Phase G1):
///   .@"error"  → "$err_<N>":  { "message": ..., "off": N, "len": N, "suggest": "..." }
///   .warning   → "$warn_<N>": { "message": ..., "off": N, "len": N, "suggest": "..." }
///   .info      → "$info_<N>": { "message": ..., "off": N, "len": N, "suggest": "..." }
///
/// `off` / `len` and `suggest` are emitted only when the corresponding
/// Diagnostic fields are non-null. The historical "plain string"
/// shape (`"$err_<N>": "message"`) was replaced by Phase G1 — the
/// object shape lets the GUI ExprPanel highlight a specific token
/// range and surface did-you-mean hints separately from the prose
/// message.
const std = @import("std");

pub const Severity = enum { @"error", warning, info };

/// One validation finding. `path` is dot-separated and points at a node
/// in the loaded config tree (not the raw JSON5 source). Source position
/// fields are 1-based and refer to the raw JSON5 bytes; they may be null
/// when the emit site doesn't have ready access to scanner position
/// (e.g. a cross-template invariant detected at end of load).
pub const Diagnostic = struct {
    path: []const u8,
    line: ?u32 = null,
    col: ?u32 = null,
    end_line: ?u32 = null,
    end_col: ?u32 = null,
    /// Byte offset inside the expression string for expr-internal
    /// findings. Useful for token highlighting in the GUI's expression
    /// panel. Null for non-expr diagnostics.
    expr_off: ?u32 = null,
    expr_len: ?u32 = null,
    severity: Severity,
    /// Machine-readable code, e.g. "config.unknown_key",
    /// "expr.unknown_function", "json5.duplicate_key". Used by the GUI
    /// for icon/route selection and by future tooling for filtering.
    code: []const u8,
    message: []const u8,
    /// Optional suggestion ("did you mean 'COALESCE'?"). Owned by the
    /// same allocator as the rest of the strings.
    suggest: ?[]const u8 = null,
};

/// Owned collector. All strings appended into Diagnostic fields are
/// expected to live as long as this collector — typically the bxp-fmt
/// arena, which is freed in one shot when the binary exits. Callers
/// that need persistent ownership across allocator boundaries should
/// dupe before append.
pub const Diagnostics = struct {
    items: std.ArrayList(Diagnostic),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Diagnostics {
        return .{ .items = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.items.deinit(self.alloc);
    }

    pub fn append(self: *Diagnostics, d: Diagnostic) !void {
        try self.items.append(self.alloc, d);
    }

    pub fn count(self: *const Diagnostics) usize {
        return self.items.items.len;
    }

    /// Number of diagnostics matching the given severity. Used by the
    /// pre-save guard (only `.@"error"` blocks save) and by the bxp-fmt
    /// summary line.
    pub fn countBySeverity(self: *const Diagnostics, sev: Severity) usize {
        var n: usize = 0;
        for (self.items.items) |d| {
            if (d.severity == sev) n += 1;
        }
        return n;
    }
};

test "Diagnostics: append + count + countBySeverity" {
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    try diag.append(.{
        .path = "conversion_templates.x.data_dir",
        .severity = .@"error",
        .code = "config.empty_required",
        .message = "data_dir must not be empty",
    });
    try diag.append(.{
        .path = "conversion_templates.x.unknown_key",
        .line = 12,
        .col = 5,
        .severity = .warning,
        .code = "config.unknown_key",
        .message = "unknown key 'unknown_key'",
        .suggest = "did you mean 'file_pattern_in'?",
    });
    try diag.append(.{
        .path = "conversion_templates.x.ticker_map",
        .severity = .info,
        .code = "config.empty_optional",
        .message = "empty ticker map; no remapping will occur",
    });

    try std.testing.expectEqual(@as(usize, 3), diag.count());
    try std.testing.expectEqual(@as(usize, 1), diag.countBySeverity(.@"error"));
    try std.testing.expectEqual(@as(usize, 1), diag.countBySeverity(.warning));
    try std.testing.expectEqual(@as(usize, 1), diag.countBySeverity(.info));
}
