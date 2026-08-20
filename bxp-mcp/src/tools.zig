// bxp-mcp — tool catalog + handlers (in-process, no spawn)
//
// Each tool calls the shared bxp-core `inspect` module directly — the same
// stateless core the GUI's bxp-gui-bridge also calls. No subprocess: a tool
// call is a function call, so latency is microseconds, not a process spawn.
//
// Handlers have the zig-libs `mcp` module's shape: `fn(ctx, *mcp.ToolCall)
// bool`. The transport (JSON-RPC framing, the handshake, tools/list, dispatch
// by name, structuredContent, progress) belongs to that module; this file is
// only the catalog and the nine handlers. `ctx` is the `App` below — the live
// `io` + `environ_map` that `bxp_simulate` needs to spawn bxp-cli.

const std = @import("std");
const inspect = @import("inspect");
const mcp = @import("mcp");
const sim = @import("sim.zig");

/// Application state threaded to every handler through the tool's `ctx`
/// pointer. Only `bxp_simulate` reads it (spawning the co-located bxp-cli
/// needs an `Io` and the environment for `tmpDir`), but every tool is
/// registered with the same ctx so the handler signature stays uniform.
pub const App = struct {
    io: std.Io,
    env: *const std.process.Environ.Map,
};

pub const Tool = enum {
    bxp_validate,
    bxp_validate_expr,
    bxp_eval,
    bxp_eval_batch,
    bxp_eval_trace,
    bxp_docs,
    bxp_list_templates,
    bxp_fetch_template,
    bxp_simulate,
};

/// One documented MCP tool. Co-located catalog (the tools module) — the same
/// grouped-array pattern as expr.zig's `operators`/`keywords`/`tokens`. The
/// `tools/list` JSON-RPC result is assembled from this catalog by the `mcp`
/// module's serializer (fed by `register` below), so the wire shape can never
/// drift from the per-tool name/description/schema. `input_schema` /
/// `output_schema` are JSON-Schema object literals (pretty-printed for
/// readability — the serializer re-emits them compact); `output_schema` is ""
/// for tools that declare none.
///
/// Deliberately NOT `mcp.Tool`: this stays a pure data table so
/// `tools/zig-doc-gen` can compile the catalog without pulling the handlers
/// (and through them `sim` → `btrace`) into the docs generator. `register`
/// is the one place that pairs a catalog row with its handler.
pub const ToolDoc = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    output_schema: []const u8 = "",

    /// How this tool is served, for the implementation map in
    /// `docs/reference/mcp-tools.md` — which `docs/dev/mcp.md` includes rather
    /// than restating. Kept here because it is a fact about the handler a few
    /// lines below, and a hand-maintained copy in prose is exactly what drifts:
    /// nothing would have caught a tenth tool never reaching that page.
    ///
    /// `inspect_call` is the `bxp-core/src/inspect.zig` entry point behind the
    /// tool (or a plain-English note where the tool is not stateless);
    /// `bridge_op` is the matching `bxp-gui-bridge` C-ABI call, empty when the
    /// GUI has no equivalent.
    inspect_call: ?[]const u8 = null,
    bridge_op: ?[]const u8 = null,
};

pub const tool_docs = [_]ToolDoc{
    .{
        .name = "bxp_validate",
        .inspect_call = "annotateRaw(config, \"<config>\", 0)",
        .bridge_op = "bridge_inspect {config}",
        .description = "Validate a bxp-cli config (JSON5). Returns annotated JSON with " ++
            "$err_/$warn/$info diagnostics inserted before each offending key.",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "config": {
        \\      "type": "string",
        \\      "description": "The full bxp-cli config text (JSON5)."
        \\    }
        \\  },
        \\  "required": [
        \\    "config"
        \\  ]
        \\}
        ,
    },
    .{
        .name = "bxp_validate_expr",
        .inspect_call = "validateExprJson(expr)",
        .bridge_op = "bridge_eval_expr",
        .description = "Validate one bxp expression the way the GUI config editor does at authoring " ++
            "time: syntax, semantics, AND static lint findings the lenient runtime silently " ++
            "swallows (e.g. a literal SPLIT_PART index of 0 — 1-based, so 0 always yields \"\" " ++
            "— or a DATE_CONVERT format with an unbracketed non-vocab letter). Returns " ++
            "{ok:true} when the expression is sound, or {ok:false,error,detail,off,len} for " ++
            "the first finding (off/len pin the offending token span). Use this when " ++
            "AUTHORING a config to catch mistakes before a run; use bxp_eval to see what an " ++
            "expression COMPUTES against a row. Mirrors the GUI's bridge_eval_expr.",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "expr": {
        \\      "type": "string",
        \\      "description": "The expression text, e.g. SPLIT_PART([Sym], '/', 1)."
        \\    }
        \\  },
        \\  "required": [
        \\    "expr"
        \\  ]
        \\}
        ,
    },
    .{
        .name = "bxp_eval",
        .inspect_call = "evalExpr(expr, headers?, fields?)",
        .description = "Evaluate one bxp expression against an optional row context. Returns {ok,value} " ++
            "or {ok:false,error,detail,off,len}. This is the lenient runtime path (what a " ++
            "real bxp-cli run computes); for authoring-time validation that flags literal " ++
            "mistakes, use bxp_validate_expr.",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "expr": {
        \\      "type": "string",
        \\      "description": "The expression text, e.g. UPPER('hi') or [Price]*[Qty]."
        \\    },
        \\    "headers": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "string"
        \\      },
        \\      "description": "Optional column header names, e.g. [\"Price\",\"Qty\"]."
        \\    },
        \\    "fields": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "string"
        \\      },
        \\      "description": "Optional row field values (parallel to headers; ragged rows tolerated)."
        \\    }
        \\  },
        \\  "required": [
        \\    "expr"
        \\  ]
        \\}
        ,
    },
    .{
        .name = "bxp_eval_batch",
        .inspect_call = "evalBatch(request)",
        .bridge_op = "bridge_inspect {eval_batch}",
        .description = "Evaluate many bxp expressions against one row in a single call. Returns " ++
            "{results:[{ok,value}|{ok:false,error,detail,off,len}, ...]} aligned to the " ++
            "input order. A well-formed request always succeeds; per-expr failures are " ++
            "carried by each result's ok flag.",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "headers": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "string"
        \\      },
        \\      "description": "Column header names."
        \\    },
        \\    "fields": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "string"
        \\      },
        \\      "description": "Row field values (parallel to headers; ragged rows tolerated)."
        \\    },
        \\    "exprs": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "string"
        \\      },
        \\      "description": "Expressions to evaluate against the row."
        \\    },
        \\    "maps": {
        \\      "type": "object",
        \\      "description": "Optional named key-value maps { name: { key: value } } resolved by REMAP (whole-value) / REPLACE (substring)."
        \\    },
        \\    "lookups": {
        \\      "type": "object",
        \\      "description": "Optional flat pre_pass lookup blob for LOOKUP() (NUL-separated name/key/field keys)."
        \\    },
        \\    "single_prepass_name": {
        \\      "type": "string",
        \\      "description": "Optional implicit pre_pass name enabling 2-arg LOOKUP(key, field)."
        \\    }
        \\  },
        \\  "required": [
        \\    "headers",
        \\    "fields",
        \\    "exprs"
        \\  ]
        \\}
        ,
    },
    .{
        .name = "bxp_eval_trace",
        .inspect_call = "evalTrace(expr, ..., out)",
        .bridge_op = "bridge_eval_expr_trace",
        .description = "Evaluate one bxp expression with a per-call execution trace. Returns NDJSON " ++
            "(one JSON object per line): one {\"fn\",\"src_start\",\"src_end\",\"value\"} line per " ++
            "function call as the engine evaluates inside-out, then a terminal line — " ++
            "{\"t\":\"final\",\"value\":\"...\"} on success or " ++
            "{\"t\":\"error\",\"error\",\"detail\",\"off\",\"len\"} on failure. Use to debug HOW a " ++
            "complex expression computes its result, beyond bxp_eval's final value.",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "expr": {
        \\      "type": "string",
        \\      "description": "The expression text."
        \\    },
        \\    "headers": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "string"
        \\      },
        \\      "description": "Optional column header names, e.g. [\"Price\",\"Qty\"]."
        \\    },
        \\    "fields": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "string"
        \\      },
        \\      "description": "Optional row field values (parallel to headers; ragged rows tolerated)."
        \\    }
        \\  },
        \\  "required": [
        \\    "expr"
        \\  ]
        \\}
        ,
    },
    .{
        .name = "bxp_docs",
        .inspect_call = "docsJson()",
        .bridge_op = "bridge_inspect {docs}",
        .description = "Return the full bxp language/schema documentation as JSON (functions, keywords, " ++
            "operators, tokens, config_schema).",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {},
        \\  "required": []
        \\}
        ,
    },
    .{
        .name = "bxp_list_templates",
        .inspect_call = "listTemplates(config)",
        .bridge_op = "bridge_inspect {list_templates}",
        .description = "List every conversion template declared in a bxp-cli config (JSON5). Returns " ++
            "{templates:[{id,data_dir,file_pattern_in,file_pattern_out,file_type_in,file_type_out,description}, " ++
            "...]}; no semantic validation, so broken templates still appear with an error " ++
            "field.",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "config": {
        \\      "type": "string",
        \\      "description": "The full bxp-cli config text (JSON5)."
        \\    }
        \\  },
        \\  "required": [
        \\    "config"
        \\  ]
        \\}
        ,
    },
    .{
        .name = "bxp_fetch_template",
        .inspect_call = "fetchTemplate(config, id)",
        .bridge_op = "bridge_inspect {fetch_template}",
        .description = "Fetch one conversion template's raw JSON by id from a bxp-cli config (JSON5). " ++
            "Returns the template object, or {\"$err_1\":\"...\"} if the id is absent.",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "config": {
        \\      "type": "string",
        \\      "description": "The full bxp-cli config text (JSON5)."
        \\    },
        \\    "id": {
        \\      "type": "string",
        \\      "description": "The template id to fetch."
        \\    }
        \\  },
        \\  "required": [
        \\    "config",
        \\    "id"
        \\  ]
        \\}
        ,
    },
    .{
        .name = "bxp_simulate",
        .description = "Run a full conversion end-to-end: stage the config (JSON5) + input CSV in a " ++
            "scratch workspace, run the chosen template through bxp-cli, and return the " ++
            "produced output, a record-count diff, bxp-cli's summary + diagnostics, and a " ++
            "per-row `trace` (BXTB sidecar): for each input row whether it was written, " ++
            "filtered (with reason: rule_skip / no_rule_match), or errored — each carrying " ++
            "the 1-based input-line number. Verifies a config for real " ++
            "(pre_pass/LOOKUP/row_rules) — what bxp_eval/bxp_validate cannot. CSV-input " ++
            "templates only. ok=true means the run happened; consult " ++
            "exit_code/status/diagnostics (0=ok, 2=warnings, 1=error).",
        .input_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "config": {
        \\      "type": "string",
        \\      "description": "The full bxp-cli config text (JSON5)."
        \\    },
        \\    "template": {
        \\      "type": "string",
        \\      "description": "The conversion template id to run."
        \\    },
        \\    "csv": {
        \\      "type": "string",
        \\      "description": "The input CSV content (becomes the single input file for the run)."
        \\    },
        \\    "workspace": {
        \\      "type": "string",
        \\      "description": "Optional scratch-workspace id (defaults to the template id). Reused across calls, so repeated runs don't litter temp with new dirs."
        \\    }
        \\  },
        \\  "required": [
        \\    "config",
        \\    "template",
        \\    "csv"
        \\  ]
        \\}
        ,
        .output_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "ok": {
        \\      "type": "boolean"
        \\    },
        \\    "template": {
        \\      "type": "string"
        \\    },
        \\    "exit_code": {
        \\      "type": "integer"
        \\    },
        \\    "status": {
        \\      "type": "string",
        \\      "enum": [
        \\        "ok",
        \\        "warnings",
        \\        "error"
        \\      ]
        \\    },
        \\    "input": {
        \\      "type": "object",
        \\      "properties": {
        \\        "records": {
        \\          "type": "integer",
        \\          "description": "Data rows in the input CSV (header excluded), so it lines up with trace.source_rows."
        \\        },
        \\        "csv": {
        \\          "type": "string"
        \\        }
        \\      }
        \\    },
        \\    "output_records": {
        \\      "type": "integer",
        \\      "description": "Total data rows across all output files (each file's header excluded), comparable to trace.written_rows."
        \\    },
        \\    "outputs": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "object",
        \\        "properties": {
        \\          "file": {
        \\            "type": "string"
        \\          },
        \\          "records": {
        \\            "type": "integer"
        \\          },
        \\          "csv": {
        \\            "type": "string"
        \\          },
        \\          "error": {
        \\            "type": "string",
        \\            "description": "Present instead of csv/records when the output file could not be read back (e.g. exceeds the 16 MB cap)."
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "summary": {
        \\      "type": "string"
        \\    },
        \\    "diagnostics": {
        \\      "type": "string"
        \\    },
        \\    "trace": {
        \\      "type": "object",
        \\      "properties": {
        \\        "available": {
        \\          "type": "boolean"
        \\        },
        \\        "source_rows": {
        \\          "type": "integer"
        \\        },
        \\        "written_rows": {
        \\          "type": "integer"
        \\        },
        \\        "errors": {
        \\          "type": "integer"
        \\        },
        \\        "warnings": {
        \\          "type": "integer"
        \\        },
        \\        "filtered": {
        \\          "type": "object",
        \\          "properties": {
        \\            "count": {
        \\              "type": "integer"
        \\            },
        \\            "sample": {
        \\              "type": "array",
        \\              "items": {
        \\                "type": "object",
        \\                "properties": {
        \\                  "input_row": {
        \\                    "type": "integer"
        \\                  },
        \\                  "source_offset": {
        \\                    "type": "integer"
        \\                  },
        \\                  "reason": {
        \\                    "type": "string"
        \\                  }
        \\                }
        \\              }
        \\            }
        \\          }
        \\        },
        \\        "row_errors": {
        \\          "type": "object",
        \\          "properties": {
        \\            "count": {
        \\              "type": "integer"
        \\            },
        \\            "sample": {
        \\              "type": "array",
        \\              "items": {
        \\                "type": "object",
        \\                "properties": {
        \\                  "input_row": {
        \\                    "type": "integer"
        \\                  },
        \\                  "source_offset": {
        \\                    "type": "integer"
        \\                  },
        \\                  "variable": {
        \\                    "type": "string"
        \\                  },
        \\                  "kind": {
        \\                    "type": "string"
        \\                  },
        \\                  "detail": {
        \\                    "type": "string"
        \\                  },
        \\                  "origin": {
        \\                    "type": "string"
        \\                  }
        \\                }
        \\              }
        \\            }
        \\          }
        \\        },
        \\        "output_rows": {
        \\          "type": "object",
        \\          "properties": {
        \\            "count": {
        \\              "type": "integer"
        \\            },
        \\            "sample": {
        \\              "type": "array",
        \\              "items": {
        \\                "type": "object",
        \\                "properties": {
        \\                  "input_row": {
        \\                    "type": "integer"
        \\                  },
        \\                  "source_offset": {
        \\                    "type": "integer"
        \\                  },
        \\                  "output_idx": {
        \\                    "type": "integer"
        \\                  },
        \\                  "rule": {
        \\                    "type": "integer"
        \\                  },
        \\                  "action": {
        \\                    "type": "string"
        \\                  }
        \\                }
        \\              }
        \\            }
        \\          }
        \\        },
        \\        "prepass_entries": {
        \\          "type": "integer"
        \\        }
        \\      }
        \\    },
        \\    "workspace": {
        \\      "type": "string"
        \\    },
        \\    "error": {
        \\      "type": "string"
        \\    },
        \\    "detail": {
        \\      "type": "string"
        \\    }
        \\  }
        \\}
        ,
    },
};

/// Register every catalog entry on an `mcp.Server`, in catalog order — which
/// is the order agents see in `tools/list`. The catalog carries the wire
/// metadata, this function pairs each row with its handler and the shared
/// `app` ctx.
///
/// `inline for` + a comptime name→enum lookup makes the pairing a compile-time
/// invariant: a catalog row whose name has no `Tool` tag fails to build, and
/// `handlerFor`'s exhaustive switch fails to build for a tag with no handler.
/// Neither can be forgotten when a tenth tool is added.
pub fn register(server: *mcp.Server, app: *App) !void {
    inline for (tool_docs) |t| {
        const tool = comptime tagFor(t.name);
        try server.addTool(.{
            .name = t.name,
            .description = t.description,
            .input_schema = t.input_schema,
            .output_schema = t.output_schema,
            .allow_structured = allowsStructured(tool),
            .handler = handlerFor(tool),
            .ctx = app,
        });
    }
}

/// Whether a tool's textual result is a single top-level JSON object eligible
/// for MCP `structuredContent`. `bxp_eval_trace` streams NDJSON (many lines, or
/// a single sentinel line for a function-free expression) — its shape is a
/// stream, not one object, so it stays text-only regardless of how few lines a
/// trivial expression happens to produce. Deciding by tool identity (not by
/// brace-scanning the output) keeps the contract stable. The `mcp` module
/// applies its own structural re-check on top of this flag.
pub fn allowsStructured(tool: Tool) bool {
    return tool != .bxp_eval_trace;
}

/// Comptime catalog-name → `Tool` tag. A hand-rolled walk over the enum's
/// fields rather than `std.meta.stringToEnum`, which builds a comptime
/// `StaticStringMap` (and its pdq sort blows the default eval-branch quota for
/// what is a nine-entry lookup done once at startup).
fn tagFor(comptime name: []const u8) Tool {
    for (@typeInfo(Tool).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return @field(Tool, f.name);
    }
    @compileError("tool_docs entry '" ++ name ++ "' has no matching Tool enum tag");
}

/// The handler for one tool. Exhaustive by design — see `register`.
fn handlerFor(comptime tool: Tool) mcp.Handler {
    return switch (tool) {
        .bxp_validate => &validate,
        .bxp_validate_expr => &validateExpr,
        .bxp_eval => &eval,
        .bxp_eval_batch => &evalBatch,
        .bxp_eval_trace => &evalTrace,
        .bxp_docs => &docs,
        .bxp_list_templates => &listTemplates,
        .bxp_fetch_template => &fetchTemplate,
        .bxp_simulate => &simulate,
    };
}

// ── tools ────────────────────────────────────────────────────────────────────
//
// Every handler returns `true` only for a tool *failure* (a missing required
// argument, an unexpected Zig error, a spawn/IO failure) so the response is
// marked `isError:true`. A domain result the tool produced on purpose —
// `{"ok":false,...}` from an expression error or an orchestration report — is
// *not* a failure (`false`): it is a valid answer the agent should read.
// `call.fail` writes the message and returns `true` in one step.
//
// `call.arena` is the per-request arena: allocate freely, never store.

fn validate(_: ?*anyopaque, call: *mcp.ToolCall) bool {
    const config = call.strArg("config") orelse return call.fail("missing 'config'");
    // check_fs = 0: pure structural/expression validation, no filesystem
    // syscalls (the agent is validating config text, not a deployed tree).
    const result = inspect.annotateRaw(call.arena, config, "<config>", 0) catch |err|
        return call.fail(@errorName(err));
    call.write(result.json);
    return false;
}

fn validateExpr(_: ?*anyopaque, call: *mcp.ToolCall) bool {
    const expr = call.strArg("expr") orelse return call.fail("missing 'expr'");
    // Authoring-time verdict (runtime eval + static FnArgDoc lint), serialized as
    // {ok:true} / {ok:false,error,…} by the shared core. A flagged expression is a
    // domain result the agent should read, not a tool failure — isError stays false.
    const result = inspect.validateExprJson(call.arena, expr) catch |err|
        return call.fail(@errorName(err));
    call.write(result);
    return false;
}

/// One row-context argument (`headers` / `fields`) of the two single-expression
/// eval tools, normalised to the JSON text `inspect` takes.
const RowArg = union(enum) {
    /// Not supplied — evaluate without a row context.
    absent,
    /// JSON text ready for `inspect.evalExpr` / `evalTrace`.
    json: []const u8,
    /// Refusal message, ready for `call.fail`.
    bad: []const u8,
};

/// Read `headers` / `fields` off the call arguments.
///
/// The canonical shape is a **native JSON array of strings** — what a model
/// writes unprompted, and what the sibling `bxp_eval_batch` already requires.
/// An array encoded *into a string* stays accepted: that was the declared shape
/// until 2026-08-19, inherited from bxp-fmt's `--row-headers` flag where an
/// argv value could carry nothing else, so a caller written against the older
/// schema keeps working.
///
/// Every other shape is refused by name rather than dropped. Dropping it —
/// which is what `strArg` returning null did for a native array — leaves every
/// `[Column]` evaluating to "" while the call still answers `ok:true`, and an
/// agent reads that as a broken *expression* rather than a bad call, then
/// "fixes" an expression that was correct.
fn rowArg(call: *mcp.ToolCall, comptime key: []const u8) RowArg {
    const wrong_shape = "'" ++ key ++ "' must be an array of strings, e.g. [\"Date\",\"Price\"]";
    if (call.args != .object) return .absent;
    const v = call.args.object.get(key) orelse return .absent;
    switch (v) {
        .null => return .absent,
        .string => |s| return .{ .json = s },
        .array => |items| {
            for (items.items) |item| if (item != .string) return .{ .bad = wrong_shape };
            // Round-trip back to JSON text: `inspect` takes the row context as a
            // JSON blob (the shape the FFI bridge must use anyway, since a C ABI
            // carries nothing else), so shape adaptation belongs here in the wire
            // adapter. A row context is a handful of short strings — the cost is
            // noise next to the eval itself.
            var aw: std.Io.Writer.Allocating = .init(call.arena);
            std.json.Stringify.value(v, .{}, &aw.writer) catch return .{ .bad = "OutOfMemory" };
            return .{ .json = aw.written() };
        },
        else => return .{ .bad = wrong_shape },
    }
}

/// Failure message for an error out of `inspect.evalExpr` / `evalTrace`.
///
/// `InvalidRowJson` is the one an agent can act on — it means a `headers` /
/// `fields` string did not hold a JSON array of strings — so it is spelled out
/// instead of surfacing as a bare Zig error name. Anything else is unexpected
/// and keeps its name.
fn evalFail(call: *mcp.ToolCall, err: anyerror) bool {
    return call.fail(switch (err) {
        error.InvalidRowJson => "'headers' and 'fields' must be arrays of strings, e.g. [\"Date\",\"Price\"]",
        else => @errorName(err),
    });
}

fn eval(_: ?*anyopaque, call: *mcp.ToolCall) bool {
    const expr = call.strArg("expr") orelse return call.fail("missing 'expr'");
    const headers = switch (rowArg(call, "headers")) {
        .absent => null,
        .json => |j| j,
        .bad => |msg| return call.fail(msg),
    };
    const fields = switch (rowArg(call, "fields")) {
        .absent => null,
        .json => |j| j,
        .bad => |msg| return call.fail(msg),
    };
    const result = inspect.evalExpr(call.arena, expr, headers, fields) catch |err|
        return evalFail(call, err);
    call.write(result);
    return false;
}

fn docs(_: ?*anyopaque, call: *mcp.ToolCall) bool {
    const result = inspect.docsJson(call.arena) catch |err|
        return call.fail(@errorName(err));
    call.write(result);
    return false;
}

fn evalBatch(_: ?*anyopaque, call: *mcp.ToolCall) bool {
    // The call arguments object *is* the batch request {headers, fields, exprs,
    // ...} — pass it straight to the shared core (no stdin/serialize round-trip).
    const result = inspect.evalBatch(call.arena, call.args) catch |err|
        return call.fail(@errorName(err));
    if (result.error_message) |msg| return call.fail(msg);
    call.write(result.json);
    return false;
}

fn evalTrace(_: ?*anyopaque, call: *mcp.ToolCall) bool {
    const expr = call.strArg("expr") orelse return call.fail("missing 'expr'");
    const headers = switch (rowArg(call, "headers")) {
        .absent => null,
        .json => |j| j,
        .bad => |msg| return call.fail(msg),
    };
    const fields = switch (rowArg(call, "fields")) {
        .absent => null,
        .json => |j| j,
        .bad => |msg| return call.fail(msg),
    };
    // Collect the NDJSON stream (per-call traces + final sentinel) into a buffer
    // and append the error sentinel (if any) so the agent gets the whole trace
    // plus outcome in one blob — the MCP analogue of fmt's stdout+stderr split.
    var aw: std.Io.Writer.Allocating = .init(call.arena);
    const result = inspect.evalTrace(call.arena, expr, headers, fields, &aw.writer) catch |err|
        return evalFail(call, err);
    const trace = aw.toOwnedSlice() catch return call.fail("OutOfMemory");
    call.write(trace);
    // An expression-error sentinel is a domain result the agent should read, not
    // a tool failure — the call succeeded in producing the trace.
    if (result.error_json) |ej| {
        call.write(ej);
        call.write("\n");
    }
    return false;
}

fn listTemplates(_: ?*anyopaque, call: *mcp.ToolCall) bool {
    const config = call.strArg("config") orelse return call.fail("missing 'config'");
    const result = inspect.listTemplates(call.arena, config) catch |err|
        return call.fail(@errorName(err));
    call.write(result);
    return false;
}

fn fetchTemplate(_: ?*anyopaque, call: *mcp.ToolCall) bool {
    const config = call.strArg("config") orelse return call.fail("missing 'config'");
    const id = call.strArg("id") orelse return call.fail("missing 'id'");
    // The result JSON is the template object on success, or {"$err_1":"..."} for
    // a missing id / unparseable config — both are useful agent-facing content
    // (a present-but-not-found id is a domain answer, not a tool failure).
    const result = inspect.fetchTemplate(call.arena, config, id) catch |err|
        return call.fail(@errorName(err));
    call.write(result.json);
    return false;
}

fn simulate(ctx: ?*anyopaque, call: *mcp.ToolCall) bool {
    // The one handler that reads the ctx: a full conversion is not a stateless
    // inspect op, so it spawns the co-located bxp-cli and needs the live `io`
    // + environment to do it.
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const config = call.strArg("config") orelse return call.fail("missing 'config'");
    const template = call.strArg("template") orelse return call.fail("missing 'template'");
    const csv_text = call.strArg("csv") orelse return call.fail("missing 'csv'");
    const workspace = call.strArg("workspace"); // optional
    // sim.simulate handles its own logical failures as {"ok":false,...} JSON (a
    // domain result, isError:false); only OOM/unexpected surfaces here as a
    // genuine tool failure.
    sim.simulate(app.io, app.env, call.arena, config, template, csv_text, workspace, call, call.out) catch |err|
        return call.fail(@errorName(err));
    return false;
}
