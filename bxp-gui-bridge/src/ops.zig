//! Catalog of the bridge's C-ABI surface. Pure data, no imports —
//! `tools/zig-doc-gen` renders it into `docs/includes/bridge-ops.md`, and
//! `main.zig` carries a comptime check that every `pub export fn bridge_*` it
//! declares has an entry here (and vice versa).
//!
//! Why: the site described this surface twice, by hand, in two places that had
//! both settled on "all five entry points" while the library was exporting ten.
//! `bridge_verify_minisign` — the updater's authenticity check — appeared on
//! neither page. The complete table existed only in `bxp-gui-bridge/CLAUDE.md`,
//! which agents read and people do not.

/// How an operation is served. The in-proc / proxy split is the whole reason
/// the bridge exists, so it is a field rather than a sentence.
pub const Kind = enum {
    /// Runs inside the GUI process, linked against bxp-core.
    in_proc,
    /// Spawns the co-located `bxp-cli` and drains its pipes in native code.
    proxy,
    /// Neither — handle lifecycle, memory ownership, version probe.
    lifecycle,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .in_proc => "in-proc",
            .proxy => "proxy",
            .lifecycle => "lifecycle",
        };
    }
};

pub const OpDoc = struct {
    /// Exported symbol name, checked at comptime against `main.zig`.
    name: []const u8,
    /// Argument shape as it reads on the Dart side, for the page only.
    args: []const u8 = "",
    kind: Kind,
    purpose: []const u8,
};

pub const ops = [_]OpDoc{
    .{ .name = "bridge_version", .args = "()", .kind = .lifecycle, .purpose = "NUL-terminated semver string, matching `build.zig.zon`. The GUI's library-probe uses it to refuse a mismatched build." },
    .{ .name = "bridge_run", .args = "(argv, out)", .kind = .proxy, .purpose = "One-shot spawn: run `bxp-cli`, drain stdout and stderr into the caller's buffer, return the exit code. Used for the `--version` probe; the native drain sidesteps the Dart pipe truncation of dart-lang/sdk#1727." },
    .{ .name = "bridge_run_streaming", .args = "(argv, callbacks)", .kind = .proxy, .purpose = "Streaming spawn: per-batch stdout / stderr callbacks plus an exit callback. Carries the `bxp-cli --trace` BXTB frame stream behind every dry-run and full run." },
    .{ .name = "bridge_cancel", .args = "(handle)", .kind = .lifecycle, .purpose = "Cooperative cancel for a streaming handle. The child leads its own process group, so this reaches its grandchildren too." },
    .{ .name = "bridge_ack", .args = "(handle)", .kind = .lifecycle, .purpose = "Backpressure acknowledgement — releases one queue permit, so a slow Dart consumer cannot be outrun by a fast producer." },
    .{ .name = "bridge_free", .args = "(ptr, len)", .kind = .lifecycle, .purpose = "Returns a response buffer to the bridge allocator. Every buffer the bridge hands out is freed through here, never by Dart." },
    .{ .name = "bridge_eval_expr", .args = "(expr, row, out)", .kind = .in_proc, .purpose = "Parse and evaluate one expression, returning the value or `{error, offset, length}`. Drives the expression editor's per-keystroke validation, which is why it must not pay a ~50 ms spawn." },
    .{ .name = "bridge_eval_expr_trace", .args = "(expr, row, out)", .kind = .in_proc, .purpose = "The same with a per-call NDJSON trace plus a terminal sentinel — the ExprPlayground's step-through view." },
    .{ .name = "bridge_inspect", .args = "(request, out)", .kind = .in_proc, .purpose = "The stateless inspect ops behind one JSON request envelope: `docs`, `config`, `list_templates`, `fetch_template`, `eval_batch`. Result JSON comes back in the out buffer." },
    .{ .name = "bridge_verify_minisign", .args = "(file, sig, pubkey)", .kind = .in_proc, .purpose = "Verifies a minisign signature over a file — the release `SHA256SUMS` — against a base64 public key. Ed25519 + Blake2b-512 through the zig-libs `minisign` module, no heap allocation, no Dart crypto dependency; returns `0` for authentic and non-zero to refuse." },
};
