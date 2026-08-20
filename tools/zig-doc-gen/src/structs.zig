//! Renders `docs/dev/architecture/data-structures.md` — the mermaid class
//! diagram of the runtime types — straight out of `@typeInfo`.
//!
//! This page used to be transcribed by hand, which is why it had drifted to
//! 11 of `BrokerConfig`'s 25 fields, 7 of `Context`'s 20, and a `SectionStats`
//! whose field names (`errors`, `empty_csv`, `elapsed_ns`) never existed. A
//! class diagram looks authoritative in a way a stale table does not, so it
//! rotted quietly. Nothing here is retyped: field names, field types and the
//! public method list all come from the compiler.
//!
//! Two things the compiler cannot know, and which therefore live in the
//! catalog below rather than on the page:
//!
//!   * `relations` — how the types compose. `Config` *owns* its brokers where
//!     `Context` merely *points at* a map; that distinction is semantic.
//!     Every endpoint is checked against the class list at comptime, so a
//!     renamed or deleted type breaks the build instead of the diagram.
//!   * `note` — the paragraph a type needs beyond its shape. Zig doc comments
//!     are not readable at comptime, so this is the same arrangement `FnDoc`
//!     and `FieldDoc` already use: the prose lives next to the catalog entry.

const std = @import("std");
const config = @import("config");
const expr = @import("expr");
const diagnostics = @import("diagnostics");
const xlsx = @import("xlsx");
const pipeline = @import("pipeline");

const ClassDoc = struct {
    T: type,
    /// Name used in the diagram. Defaults to the type's own short name; set it
    /// only where the source name would be ambiguous on the page.
    name: []const u8 = "",
    note: []const u8 = "",
};

/// One relation edge. `kind` is mermaid's own arrow syntax.
const Relation = struct {
    from: []const u8,
    kind: []const u8,
    to: []const u8,
    label: []const u8 = "",
};

/// A named type alias the codebase reads by its own name (`MapRegistry`) even
/// though it is a bare `std` container underneath. Listing it here is what
/// keeps `BrokerConfig.maps` from rendering as a hash map of a hash map of a
/// string — mermaid's `~T~` generics do not nest, and the nested form is
/// unreadable anyway. The expansion column is still generated, so the alias
/// cannot claim to be something it stopped being.
const AliasDoc = struct {
    T: type,
    name: []const u8,
    note: []const u8 = "",
};

// Matching is by type identity, which in Zig is structural for instantiated
// generics: `expr.NamedMap` and `BrokerConfig.input_schema` are the SAME
// `StringArrayHashMapUnmanaged([]const u8)`, so aliasing the former would
// relabel the latter into something it is not. Only names whose underlying
// type is unique in this catalog belong here.
const aliases = [_]AliasDoc{
    .{ .T = expr.MapRegistry, .name = "MapRegistry", .note = "Each template's resolved named-map view: the top-level `maps` registry merged with the template's own block, template-local winning on a name collision, built once at config-load time. Its values are `expr.NamedMap`s, which preserve JSON key order — which is why `REPLACE` applies a map's pairs in declaration order, while `REMAP` uses the same map for an O(1) whole-value lookup." },
};

const classes = [_]ClassDoc{
    .{ .T = config.Config, .note = "The whole loaded `bxp-cli.json`: a template registry plus the arena every string in it points into. `deinit()` frees the lot; nothing below it owns its own memory." },
    .{ .T = config.BrokerConfig, .note = "One template. Everything the engine needs to turn one family of input files into one family of output files — where to read, how to parse, what to compute, where to write. The field-by-field reference with defaults and validation rules is the generated [config schema](../../reference/config-schema.md)." },
    .{ .T = config.PrePass },
    .{ .T = config.RowRule },
    .{ .T = config.OutputColumn },
    .{ .T = config.XlsxSheet },
    .{ .T = config.ZipInput },
    .{ .T = xlsx.SheetSpec, .note = "The runtime form of `XlsxSheet`: the same three values, handed to the converter once the config layer is out of the picture." },
    .{ .T = expr.Value, .note = "The result of evaluating one expression — a tagged union, not a string. `decimal` is the fixed-point `i128` core, so `75,00` and `75.00` compare equal without a float ever appearing." },
    .{ .T = expr.Context, .note = "Everything one expression can see while it is being evaluated: the current row, the column index, the resolved named maps, the active `pre_pass` lookup, and the out-parameters an error or a trace writes back through. Built once per row, not per expression." },
    .{ .T = diagnostics.Diagnostics, .note = "The structured finding collector behind config validation. `bxp-cli` passes a null sink and pays nothing; `bxp-mcp` and the GUI bridge collect into it and turn each entry into an `$err_<N>` / `$warn_<N>` / `$info_<N>` sibling." },
    .{ .T = diagnostics.Diagnostic },
    .{ .T = pipeline.SectionStats, .note = "`bxp-cli`'s per-section accumulator — one per template plus a top-level total. `warnings` ticks the exit code from 0 to 2 even when the run completes; `has_fatal` pushes it to 1. The row and file counters exist for the `--debug=json` run summary and are ignored by the human one." },
};

const relations = [_]Relation{
    .{ .from = "Config", .kind = "\"1\" *-- \"many\"", .to = "BrokerConfig" },
    .{ .from = "BrokerConfig", .kind = "\"1\" *-- \"0..*\"", .to = "PrePass" },
    .{ .from = "BrokerConfig", .kind = "\"1\" *-- \"0..*\"", .to = "RowRule" },
    .{ .from = "BrokerConfig", .kind = "\"1\" *-- \"many\"", .to = "OutputColumn" },
    .{ .from = "BrokerConfig", .kind = "\"1\" *-- \"0..1\"", .to = "XlsxSheet" },
    .{ .from = "BrokerConfig", .kind = "\"1\" *-- \"0..1\"", .to = "ZipInput" },
    .{ .from = "XlsxSheet", .kind = "..>", .to = "SheetSpec", .label = "runtime form for xlsx.zig" },
    .{ .from = "Context", .kind = "-->", .to = "Value", .label = "eval returns" },
    .{ .from = "Diagnostics", .kind = "\"1\" *-- \"many\"", .to = "Diagnostic" },
};

// Every relation endpoint must name a class the diagram actually renders.
// Without this a renamed type would leave mermaid drawing an empty box, which
// is exactly the silent-rot failure this generator exists to end.
comptime {
    @setEvalBranchQuota(200_000);
    for (relations) |r| {
        if (!isClass(r.from)) @compileError("relation endpoint is not a documented class: " ++ r.from);
        if (!isClass(r.to)) @compileError("relation endpoint is not a documented class: " ++ r.to);
    }
}

fn isClass(comptime name: []const u8) bool {
    for (classes) |c| {
        if (std.mem.eql(u8, className(c), name)) return true;
    }
    return false;
}

fn className(comptime c: ClassDoc) []const u8 {
    return if (c.name.len > 0) c.name else shortName(@typeName(c.T));
}

/// Drop the module path from a type name, keeping the type itself: leading
/// dot-separated segments that start lowercase are package/file names
/// (`config.`, `root.`, `mem.`), the rest is the type (`Io.Writer` survives
/// whole, since `Io` is a type too).
fn shortName(comptime full: []const u8) []const u8 {
    return comptime blk: {
        var start: usize = 0;
        var i: usize = 0;
        while (i < full.len) : (i += 1) {
            // A generic argument list opens here; whatever precedes it is
            // already the base name, and its arguments keep their own paths.
            if (full[i] == '(') break;
            if (full[i] != '.') continue;
            if (!std.ascii.isLower(full[start])) break;
            start = i + 1;
        }
        break :blk full[start..];
    };
}

/// Human-readable label for one field's type. Slices, optionals and pointers
/// unwrap; the std containers collapse to the names the codebase calls them by
/// (`StringArrayHashMap~V~`), because their real `@typeName` is a four-argument
/// generic nobody would read twice.
fn typeLabel(comptime T: type) []const u8 {
    return comptime blk: {
        if (T == []const u8) break :blk "string";
        if (T == std.mem.Allocator) break :blk "Allocator";
        for (aliases) |a| {
            if (a.T == T) break :blk a.name;
        }

        break :blk switch (@typeInfo(T)) {
            .optional => |o| "?" ++ typeLabel(o.child),
            .pointer => |p| switch (p.size) {
                .slice => "[]" ++ typeLabel(p.child),
                // A `*const HashMap` in Context is a borrow, not a distinct shape.
                .one => typeLabel(p.child),
                else => shortName(@typeName(T)),
            },
            .array => |a| std.fmt.comptimePrint("[{d}]", .{a.len}) ++ typeLabel(a.child),
            .int, .float, .bool, .void => @typeName(T),
            else => container(T),
        };
    };
}

fn container(comptime T: type) []const u8 {
    return comptime blk: {
        // Both std hash-map families expose `KV`; only the array-backed one
        // keeps insertion order, which is the distinction the config layer
        // depends on (`REPLACE` applies a map's pairs in declaration order).
        if (@hasDecl(T, "KV")) {
            const K = @FieldType(T.KV, "key");
            const V = @FieldType(T.KV, "value");
            // Match on the container's own path, not on the whole type name:
            // `StringHashMap(NamedMap)` spells its ordered VALUE type inside
            // the parentheses, and a naive search would call the outer map
            // ordered because of what it holds.
            const name = @typeName(T);
            const head = name[0 .. std.mem.indexOfScalar(u8, name, '(') orelse name.len];
            const ordered = std.mem.indexOf(u8, head, "array_hash_map") != null;
            const base = if (K == []const u8)
                (if (ordered) "StringArrayHashMap" else "StringHashMap")
            else
                (if (ordered) "ArrayHashMap" else "HashMap");
            break :blk base ++ "~" ++ typeLabel(V) ++ "~";
        }
        if (@hasDecl(T, "Slice") and @hasField(T, "items")) {
            break :blk "ArrayList~" ++ typeLabel(@typeInfo(@FieldType(T, "items")).pointer.child) ++ "~";
        }
        break :blk shortName(@typeName(T));
    };
}

pub fn write(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\---
        \\description: "The runtime types of a conversion, rendered from the Zig type definitions themselves."
        \\---
        \\
        \\# Data structures
        \\
        \\<!-- GENERATED by tools/zig-doc-gen from @typeInfo. Do not edit. -->
        \\
        \\The runtime shape of a `bxp-cli` run, read out of the types themselves —
        \\field names, field types and public methods are what the compiler sees, so
        \\this diagram cannot fall behind the code.
        \\
        \\```mermaid
        \\classDiagram
        \\
    );

    inline for (classes) |c| {
        try w.print("    class {s} {{\n", .{className(c)});
        const info = @typeInfo(c.T);
        // A leading underscore marks an implementation detail the type keeps
        // for itself (`Config._alloc`); it is not part of the shape a reader
        // of this page is looking at.
        switch (info) {
            .@"struct" => |s| inline for (s.fields) |f| {
                if (f.name[0] != '_') try w.print("        +{s}: {s}\n", .{ f.name, typeLabel(f.type) });
            },
            .@"union" => |u| inline for (u.fields) |f| {
                if (f.name[0] != '_') try w.print("        +{s}: {s}\n", .{ f.name, typeLabel(f.type) });
            },
            .@"enum" => |e| inline for (e.fields) |f| {
                try w.print("        +{s}\n", .{f.name});
            },
            else => @compileError("documented type is neither struct, union nor enum: " ++ @typeName(c.T)),
        }
        const decls = switch (info) {
            .@"struct" => |s| s.decls,
            .@"union" => |u| u.decls,
            .@"enum" => |e| e.decls,
            else => unreachable,
        };
        inline for (decls) |d| {
            if (@typeInfo(@TypeOf(@field(c.T, d.name))) == .@"fn") {
                try w.print("        +{s}()\n", .{d.name});
            }
        }
        try w.writeAll("    }\n\n");
    }

    inline for (relations) |r| {
        try w.print("    {s} {s} {s}", .{ r.from, r.kind, r.to });
        if (r.label.len > 0) try w.print(" : {s}", .{r.label});
        try w.writeByte('\n');
    }
    try w.writeAll("```\n");

    try w.writeAll(
        \\
        \\## Type aliases
        \\
        \\Names the code uses for a bare `std` container. They carry no fields of
        \\their own, so they are spelled out here rather than drawn as classes.
        \\
        \\
    );
    try w.writeAll("| Alias | Expands to |\n| --- | --- |\n");
    inline for (aliases) |a| {
        // `container`, not `typeLabel` — the latter would resolve the alias
        // straight back to its own name.
        try w.print("| <code class=\"hl-type\">{s}</code> | <code>{s}</code> |\n", .{ a.name, container(a.T) });
    }

    // The notes, in the same order as the classes above, so the page reads
    // top-down: shape first, then the paragraph each type needs.
    inline for (classes) |c| {
        if (c.note.len > 0) {
            try w.print("\n**`{s}`** — {s}\n", .{ className(c), c.note });
        }
    }
    inline for (aliases) |a| {
        if (a.note.len > 0) {
            try w.print("\n**`{s}`** — {s}\n", .{ a.name, a.note });
        }
    }
}
