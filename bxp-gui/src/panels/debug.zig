//! Step-debugger panel for the dry-run simulator.
//!
//! Shown in place of the form editor when `state.view_mode == .debug`. Lays out
//! controls (Start / Step Prev / Step Next), then for the selected input row
//! renders four stacked sections:
//!   1. raw CSV fields
//!   2. input_schema variables (value or error)
//!   3. row_rules trace (which `when` matched)
//!   4. resulting output rows (output_schema headers + cells, plus any per-row overrides)
//!
//! When the simulation has a `pre_pass` table, a fifth collapsible section
//! shows its full contents (independent of the selected row).

const std = @import("std");
const dvui = @import("dvui");
const app = @import("../app.zig");
const highlighter = @import("../expr_editor/highlighter.zig");

pub fn render(state: *app.AppState) !void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    controls(state);

    const sim_ptr = if (state.simulation) |*s| s else {
        emptyState();
        return;
    };

    if (sim_ptr.error_message.len > 0) {
        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .style = .err,
            .background = true,
            .margin = .all(12),
            .padding = .all(8),
        });
        tl.addText(sim_ptr.error_message, .{});
        tl.deinit();
        return;
    }

    if (sim_ptr.rows.len == 0) {
        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .margin = .all(12),
        });
        tl.addText("Input file has no data rows.", .{});
        tl.deinit();
        return;
    }

    if (state.debug_row_idx >= sim_ptr.rows.len) {
        state.debug_row_idx = sim_ptr.rows.len - 1;
    }
    const row = &sim_ptr.rows[state.debug_row_idx];

    sourceHeader(sim_ptr.source_path, state.debug_row_idx, sim_ptr.rows.len);

    sectionHeader(0, "Raw CSV fields");
    rawFieldsTable(sim_ptr.headers, row.raw_fields);

    sectionHeader(1, "input_schema variables");
    varTable(row.vars);

    sectionHeader(2, "row_rules");
    rulesTable(row.rules, row.matched_rule);

    sectionHeader(3, "Output rows");
    outputRows(sim_ptr.output_headers, row.output_rows);

    if (sim_ptr.pre_pass.len > 0) {
        sectionHeader(4, "Pre-pass lookup table");
        prePassTable(sim_ptr.pre_pass);
    }
}

fn emptyState() void {
    var tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .margin = .all(12),
    });
    tl.addText("Select a template and press \"Start Dry-Run\" to populate the debugger.", .{});
    tl.deinit();
}

fn controls(state: *app.AppState) void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 12, .y = 8, .w = 12, .h = 4 },
    });
    defer hbox.deinit();

    if (dvui.button(@src(), "Start Dry-Run", .{}, .{})) {
        const idx = state.selected_template orelse return;
        state.startSimulation(idx) catch |err| {
            std.log.err("startSimulation: {s}", .{@errorName(err)});
        };
    }
    if (dvui.button(@src(), "◀ Prev", .{}, .{ .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 } })) {
        state.stepRow(-1);
    }
    if (dvui.button(@src(), "Next ▶", .{}, .{ .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 } })) {
        state.stepRow(1);
    }
    if (dvui.button(@src(), "Form view", .{}, .{ .margin = .{ .x = 16, .y = 0, .w = 0, .h = 0 } })) {
        state.view_mode = .form;
    }
}

fn sourceHeader(path: []const u8, idx: usize, total: usize) void {
    var tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .margin = .{ .x = 12, .y = 4, .w = 12, .h = 6 },
    });
    tl.format("Row {d} / {d}  —  {s}", .{ idx + 1, total, path }, .{});
    tl.deinit();
}

fn sectionHeader(id_extra: usize, title: []const u8) void {
    _ = dvui.separator(@src(), .{ .id_extra = id_extra, .expand = .horizontal, .margin = .{ .x = 12, .y = 8, .w = 12, .h = 0 } });
    var tl = dvui.textLayout(@src(), .{}, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .font = .theme(.heading),
        .margin = .{ .x = 12, .y = 2, .w = 12, .h = 4 },
    });
    tl.addText(title, .{});
    tl.deinit();
}

fn rawFieldsTable(headers: []const []const u8, fields: []const []const u8) void {
    const n = @max(headers.len, fields.len);
    for (0..n) |i| {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .margin = .{ .x = 20, .y = 1, .w = 12, .h = 1 },
        });
        defer hbox.deinit();

        const hdr = if (i < headers.len) headers[i] else "";
        const val = if (i < fields.len) fields[i] else "";

        var lbl = dvui.textLayout(@src(), .{}, .{
            .min_size_content = .{ .w = 200, .h = 0 },
            .font = .theme(.mono),
        });
        lbl.addText(hdr, .{});
        lbl.deinit();

        var v = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .font = .theme(.mono),
        });
        v.addText(val, .{});
        v.deinit();
    }
}

fn varTable(vars: []const @import("../simulator.zig").VarTrace) void {
    if (vars.len == 0) {
        var tl = dvui.textLayout(@src(), .{}, .{
            .margin = .{ .x = 20, .y = 2, .w = 12, .h = 2 },
        });
        tl.addText("(no variables)", .{});
        tl.deinit();
        return;
    }
    for (vars, 0..) |v, i| {
        varRow(i, v.name, v.expr_text, v.value, v.error_text);
    }
}

fn varRow(idx: usize, name: []const u8, expr_text: []const u8, value: []const u8, err_text: []const u8) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = idx,
        .expand = .horizontal,
        .margin = .{ .x = 20, .y = 2, .w = 12, .h = 4 },
        .padding = .all(4),
        .background = true,
    });
    defer box.deinit();

    var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer head.deinit();

    {
        var n = dvui.textLayout(@src(), .{}, .{
            .min_size_content = .{ .w = 140, .h = 0 },
            .font = .theme(.mono),
            .style = .control,
        });
        n.addText(name, .{});
        n.deinit();
    }

    {
        var e = dvui.textLayout(@src(), .{}, .{
            .min_size_content = .{ .w = 280, .h = 0 },
            .font = .theme(.mono),
        });
        highlighter.addHighlighted(&e, expr_text);
        e.deinit();
    }

    {
        var v = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .font = .theme(.mono),
            .style = if (err_text.len > 0) .err else .highlight,
        });
        if (err_text.len > 0) {
            v.addText(err_text, .{});
        } else if (value.len == 0) {
            v.addText("(empty)", .{});
        } else {
            v.addText(value, .{});
        }
        v.deinit();
    }
}

fn rulesTable(rules: []const @import("../simulator.zig").RuleTrace, matched: ?usize) void {
    if (rules.len == 0) {
        var tl = dvui.textLayout(@src(), .{}, .{
            .margin = .{ .x = 20, .y = 2, .w = 12, .h = 2 },
        });
        tl.addText("(no row_rules — single output row built from input_schema)", .{});
        tl.deinit();
        return;
    }
    for (rules, 0..) |rule, i| {
        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .margin = .{ .x = 20, .y = 2, .w = 12, .h = 2 },
            .padding = .all(4),
        });
        defer box.deinit();

        const marker: []const u8 = if (rule.matched) "▶" else if (matched != null and i > matched.?) "·" else " ";
        {
            var lbl = dvui.textLayout(@src(), .{ .break_lines = false }, .{
                .min_size_content = .{ .w = 24, .h = 0 },
                .font = .theme(.mono),
                .style = if (rule.matched) .highlight else null,
            });
            lbl.addText(marker, .{});
            lbl.deinit();
        }
        {
            var idx_tl = dvui.textLayout(@src(), .{ .break_lines = false }, .{
                .min_size_content = .{ .w = 70, .h = 0 },
                .font = .theme(.mono),
            });
            idx_tl.format("rule {d}", .{rule.rule_idx + 1}, .{});
            idx_tl.deinit();
        }
        {
            var when_tl = dvui.textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .font = .theme(.mono),
            });
            highlighter.addHighlighted(&when_tl, rule.when_text);
            when_tl.deinit();
        }
        {
            const status: []const u8 = if (rule.error_text.len > 0)
                rule.error_text
            else if (rule.matched)
                "true → matched"
            else if (rule.when_truthy)
                "true (skipped — earlier rule matched)"
            else
                "false";
            var st = dvui.textLayout(@src(), .{}, .{
                .min_size_content = .{ .w = 200, .h = 0 },
                .font = .theme(.mono),
                .style = if (rule.error_text.len > 0) .err else if (rule.matched) .highlight else null,
            });
            st.addText(status, .{});
            st.deinit();
        }
    }
}

fn outputRows(headers: []const []const u8, rows: []const @import("../simulator.zig").OutputRowTrace) void {
    if (rows.len == 0) {
        var tl = dvui.textLayout(@src(), .{}, .{
            .margin = .{ .x = 20, .y = 2, .w = 12, .h = 2 },
        });
        tl.addText("(no output — row was filtered)", .{});
        tl.deinit();
        return;
    }
    for (rows, 0..) |row, ri| {
        var rbox = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = ri,
            .expand = .horizontal,
            .margin = .{ .x = 20, .y = 4, .w = 12, .h = 4 },
            .padding = .all(4),
            .background = true,
        });
        defer rbox.deinit();

        const n = @max(headers.len, row.cells.len);
        for (0..n) |ci| {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = ci,
                .expand = .horizontal,
            });
            defer hbox.deinit();

            const hdr = if (ci < headers.len) headers[ci] else "";
            const val = if (ci < row.cells.len) row.cells[ci] else "";

            var lbl = dvui.textLayout(@src(), .{}, .{
                .min_size_content = .{ .w = 200, .h = 0 },
                .font = .theme(.mono),
            });
            lbl.addText(hdr, .{});
            lbl.deinit();

            var v = dvui.textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .font = .theme(.mono),
            });
            if (val.len == 0) v.addText("(empty)", .{}) else v.addText(val, .{});
            v.deinit();
        }

        if (row.overrides.len > 0) {
            var ohdr = dvui.textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = 4, .w = 0, .h = 2 },
            });
            ohdr.addText("row_rules overrides:", .{});
            ohdr.deinit();
            for (row.overrides, 0..) |ov, oi| {
                varRow(oi + 1000 * (ri + 1), ov.name, ov.expr_text, ov.value, ov.error_text);
            }
        }
    }
}

fn prePassTable(entries: []const @import("../simulator.zig").PrePassEntry) void {
    var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 20, .y = 2, .w = 12, .h = 2 },
    });
    {
        var k = dvui.textLayout(@src(), .{}, .{
            .min_size_content = .{ .w = 240, .h = 0 },
            .font = .theme(.heading),
        });
        k.addText("key", .{});
        k.deinit();
    }
    {
        var f = dvui.textLayout(@src(), .{}, .{
            .min_size_content = .{ .w = 160, .h = 0 },
            .font = .theme(.heading),
        });
        f.addText("field", .{});
        f.deinit();
    }
    {
        var v = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .font = .theme(.heading),
        });
        v.addText("value", .{});
        v.deinit();
    }
    hdr.deinit();

    for (entries, 0..) |e, i| {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .margin = .{ .x = 20, .y = 1, .w = 12, .h = 1 },
        });
        defer hbox.deinit();

        var k = dvui.textLayout(@src(), .{}, .{
            .min_size_content = .{ .w = 240, .h = 0 },
            .font = .theme(.mono),
        });
        k.addText(e.key, .{});
        k.deinit();

        var f = dvui.textLayout(@src(), .{}, .{
            .min_size_content = .{ .w = 160, .h = 0 },
            .font = .theme(.mono),
        });
        f.addText(e.field, .{});
        f.deinit();

        var v = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .font = .theme(.mono),
        });
        v.addText(e.value, .{});
        v.deinit();
    }
}
