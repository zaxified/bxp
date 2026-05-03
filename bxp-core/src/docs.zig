/// Aggregates and serializes the full documentation surface that
/// `bxp-fmt --docs` exposes to the GUI:
///
///   * Expression catalog (functions / keywords / operators / tokens) —
///     re-exported live from `bxp-core/src/expr.zig` where each `FnDoc`
///     sits next to the builtin it documents.
///   * Config schema (`config_schema` array of FieldDoc) — assembled from
///     two sources: per-struct `pub const fields` tables co-located with
///     each config struct in `bxp-core/src/config.zig`, plus the
///     "envelope" entries declared below for slots that aren't backed by
///     a struct (top-level keys, map wildcards, the legacy pre_pass
///     single-block form).
///
/// The output JSON shape is the GUI contract — see
/// `bxp-gui/lib/store/trace_store.dart` (`functions`, `keywords`,
/// `operators`, `tokens`, `config_schema`) and
/// `bxp-gui/lib/store/schema_gate.dart` (FieldDoc consumption).
const std = @import("std");
const config = @import("config");
const expr = @import("expr");
const json5 = @import("json5");

const FieldDoc = config.FieldDoc;

// Function list flattened from expr.builtins (keeping the iteration order
// the GUI sees today).
const functions = blk: {
    var arr: [expr.builtins.len]expr.FnDoc = undefined;
    for (expr.builtins, 0..) |b, i| arr[i] = b.doc;
    break :blk arr;
};
const keywords = expr.keywords;
const operators = expr.operators;
const tokens = expr.tokens;

// ── Schema-tree bindings ─────────────────────────────────────────────────────
//
// Each binding takes a config struct's `fields` table (with relative key
// names) and slots it under a path prefix in the JSON tree. The serializer
// joins prefix + "." + entry.key to produce the flat full-path keys the
// GUI consumes (e.g. "conversion_templates.*.pre_pass.*.when").

const StructBinding = struct {
    prefix: []const u8,
    fields: []const FieldDoc,
};

const struct_bindings = [_]StructBinding{
    .{ .prefix = "conversion_templates.*",             .fields = &config.BrokerConfig.fields },
    .{ .prefix = "conversion_templates.*.xlsx_sheet",  .fields = &config.XlsxSheet.fields },
    .{ .prefix = "conversion_templates.*.row_rules.*", .fields = &config.RowRule.fields },
    .{ .prefix = "conversion_templates.*.pre_pass.*",  .fields = &config.PrePass.fields },
};

// ── Envelope entries ─────────────────────────────────────────────────────────
//
// Schema slots that aren't backed by a Zig struct: top-level keys, map
// wildcards (`*`), and the legacy pre_pass single-block form. These carry
// their full dotted path in `key`.
//
// The named-block form's per-field docs come from PrePass.fields (via
// struct_bindings); the legacy form's flat children (when/key/values) are
// listed here so the GUI keeps recognising old configs.

const envelope_entries = [_]FieldDoc{
    .{
        .key = "ticker_maps",
        .type_name = "object",
        .required = false,
        .description = "Named ticker remapping tables. Each entry: map_name -> { broker_symbol: yahoo_symbol }. Referenced by templates via ticker_map: map_name.",
        .insert_order = "alpha",
        .insert_template = "{}",
    },
    .{
        .key = "ticker_maps.*",
        .type_name = "object",
        .required = false,
        .description = "One named ticker map. Keys are broker symbols, values are the remapped target symbols (typically Yahoo Finance tickers).",
        .insert_order = "alpha",
        .insert_template =
        \\{ BROKER_SYMBOL: "YAHOO_SYMBOL" }
        ,
    },
    .{
        .key = "conversion_templates",
        .type_name = "object",
        .required = true,
        .description = "Map of template_id -> broker config. Each key is a unique template identifier used with --template flag. When bxp-cli runs without --template, all templates execute in declaration order.",
        .ordered = true,
        .insert_order = "append",
        .insert_template = "{}",
    },
    .{
        .key = "conversion_templates.*",
        .type_name = "object",
        .required = false,
        .description = "One conversion template — see `conversion_templates.*.*` fields for contents.",
        .insert_order = "schema",
        .insert_template = config.BrokerConfig.scaffold_template,
    },
    .{
        .key = "conversion_templates.*.input_schema.*",
        .type_name = "expression",
        .required = true,
        .description = "Expression evaluated per input row. Result stored in the $variable. Use [ColumnName] to reference input CSV columns.",
    },
    .{
        .key = "conversion_templates.*.output_schema.*",
        .type_name = "string",
        .required = true,
        .description = "$variable whose evaluated value fills this output column. Must start with $.",
        .insert_template = "\"$variable\"",
    },
    .{
        .key = "conversion_templates.*.row_rules.*",
        .type_name = "object",
        .required = false,
        .description = "One row rule. Schema-ordered children: `when` (condition), `rows` (output rows produced when matched).",
        .insert_order = "schema",
        .insert_template = config.RowRule.scaffold_template,
    },
    .{
        .key = "conversion_templates.*.row_rules.*.rows.*",
        .type_name = "object",
        .required = false,
        .description = "One output row. Map of $variable -> expression overriding the value from input_schema. Empty object {} = take all values verbatim from input_schema.",
        .insert_order = "append",
        .insert_template = "{}",
    },
    // ── Legacy pre_pass single-block form ───────────────────────────────────
    .{
        .key = "conversion_templates.*.pre_pass.when",
        .type_name = "expression",
        .required = true,
        .description = "Legacy single-block form. Filter — only rows matching this condition are added to the lookup table.",
    },
    .{
        .key = "conversion_templates.*.pre_pass.key",
        .type_name = "expression",
        .required = true,
        .description = "Legacy single-block form. Expression evaluated per row to produce the lookup key string.",
    },
    .{
        .key = "conversion_templates.*.pre_pass.values",
        .type_name = "object",
        .required = true,
        .description = "Legacy single-block form. Map of field_name -> expression. Each value is evaluated per pre-pass row and stored for retrieval via LOOKUP(key, 'field_name'). Field names have no $ prefix.",
        .insert_order = "append",
    },
    .{
        .key = "conversion_templates.*.pre_pass.values.*",
        .type_name = "expression",
        .required = true,
        .description = "Expression evaluated per pre-pass row. Result stored under the field name for LOOKUP retrieval.",
    },
    // ── Named pre_pass blocks ───────────────────────────────────────────────
    .{
        .key = "conversion_templates.*.pre_pass.*",
        .type_name = "object",
        .required = false,
        .description = "Named pre_pass block. The map key is the block name and becomes part of the LOOKUP namespace; different names cannot collide.",
        .insert_order = "schema",
        .insert_template = config.PrePass.scaffold_template,
    },
    .{
        .key = "conversion_templates.*.pre_pass.*.values.*",
        .type_name = "expression",
        .required = true,
        .description = "Expression evaluated per pre-pass row. Result stored under the field name for LOOKUP retrieval.",
    },
};

// ── Serializer ───────────────────────────────────────────────────────────────

pub fn writeDocs(alloc: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var jw: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };

    try jw.beginObject();

    // functions
    try jw.objectField("functions");
    try jw.beginArray();
    for (functions) |f| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(f.name);
        try jw.objectField("signature");
        try jw.write(f.signature);
        try jw.objectField("description");
        try jw.write(f.description);
        try jw.endObject();
    }
    try jw.endArray();

    // keywords
    try jw.objectField("keywords");
    try jw.beginArray();
    for (keywords) |k| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(k.name);
        try jw.objectField("description");
        try jw.write(k.description);
        try jw.endObject();
    }
    try jw.endArray();

    // operators
    try jw.objectField("operators");
    try jw.beginArray();
    for (operators) |op| {
        try jw.beginObject();
        try jw.objectField("token");
        try jw.write(op.token);
        try jw.objectField("description");
        try jw.write(op.description);
        try jw.endObject();
    }
    try jw.endArray();

    // tokens
    try jw.objectField("tokens");
    try jw.beginArray();
    for (tokens) |tok| {
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(tok.kind);
        try jw.objectField("syntax");
        try jw.write(tok.syntax);
        try jw.objectField("description");
        try jw.write(tok.description);
        try jw.endObject();
    }
    try jw.endArray();

    // config_schema
    try jw.objectField("config_schema");
    try jw.beginArray();
    for (envelope_entries) |f| try writeSchemaEntry(alloc, &jw, f.key, f);
    for (struct_bindings) |bind| {
        for (bind.fields) |f| {
            const full = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ bind.prefix, f.key });
            defer alloc.free(full);
            try writeSchemaEntry(alloc, &jw, full, f);
        }
    }
    try jw.endArray();

    try jw.endObject();
    try writer.writeByte('\n');
}

fn writeSchemaEntry(alloc: std.mem.Allocator, jw: *std.json.Stringify, full_key: []const u8, f: FieldDoc) !void {
    try jw.beginObject();
    try jw.objectField("key");
    try jw.write(full_key);
    try jw.objectField("type_name");
    try jw.write(f.type_name);
    try jw.objectField("required");
    try jw.write(f.required);
    try jw.objectField("default");
    if (f.default) |d| try jw.write(d) else try jw.write(null);
    try jw.objectField("description");
    try jw.write(f.description);
    try jw.objectField("enum_values");
    if (f.enum_values) |vs| {
        try jw.beginArray();
        for (vs) |v| try jw.write(v);
        try jw.endArray();
    } else try jw.write(null);
    try jw.objectField("ordered");
    try jw.write(f.ordered);
    try jw.objectField("insert_order");
    if (f.insert_order) |s| try jw.write(s) else try jw.write(null);
    try jw.objectField("insert_template");
    if (f.insert_template) |snippet| {
        // JSON5 (source-side) → JSON → std.json.Value → emit nested.
        // Failures here surface as runtime errors during `bxp-fmt --docs`,
        // catching template typos early.
        const json_bytes = try json5.preprocess(alloc, snippet);
        defer alloc.free(json_bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
        defer parsed.deinit();
        try jw.write(parsed.value);
    } else {
        try jw.write(null);
    }
    try jw.endObject();
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "config_schema covers known paths" {
    const testing = std.testing;

    // Total flattened entry count — guard against accidental drift when
    // adding/removing struct fields or envelope entries.
    var total: usize = envelope_entries.len;
    for (struct_bindings) |bind| total += bind.fields.len;
    try testing.expectEqual(@as(usize, 41), total);

    // Spot-check that representative paths from each binding category are
    // present. Comptime walk; failure points at the missing key.
    const wanted = [_][]const u8{
        "ticker_maps",
        "ticker_maps.*",
        "conversion_templates",
        "conversion_templates.*",
        "conversion_templates.*.data_dir",
        "conversion_templates.*.xlsx_sheet",
        "conversion_templates.*.xlsx_sheet.name",
        "conversion_templates.*.row_rules.*",
        "conversion_templates.*.row_rules.*.when",
        "conversion_templates.*.pre_pass.when",
        "conversion_templates.*.pre_pass.*",
        "conversion_templates.*.pre_pass.*.values",
    };
    for (wanted) |w| {
        var found = false;
        for (envelope_entries) |f| {
            if (std.mem.eql(u8, f.key, w)) {
                found = true;
                break;
            }
        }
        if (!found) for (struct_bindings) |bind| {
            for (bind.fields) |f| {
                if (w.len > bind.prefix.len + 1 and
                    std.mem.startsWith(u8, w, bind.prefix) and
                    w[bind.prefix.len] == '.' and
                    std.mem.eql(u8, w[bind.prefix.len + 1 ..], f.key))
                {
                    found = true;
                    break;
                }
            }
            if (found) break;
        };
        try testing.expect(found);
    }
}
