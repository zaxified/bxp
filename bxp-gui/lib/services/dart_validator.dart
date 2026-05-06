/// Phase 3 + 4: native Dart validator that consumes the `bxp-fmt --docs`
/// catalog and emits per-edit diagnostics WITHOUT a bxp-fmt subprocess
/// round-trip. Tree-level checks live next to expression-level checks
/// because both share the AST + token walker plumbing.
///
/// The validator is deliberately a thin interpreter of FnDoc/FieldDoc
/// metadata produced by `bxp-core/src/expr.zig` + `config.zig`. It does
/// not re-implement Zig validation logic from scratch; every specialised
/// check (per-arg ArgKind, per-field FieldValidator) is driven by the
/// catalog so the Zig and Dart sides cannot drift.
///
/// The Dart-side coverage doc lives next to this file:
/// `dart_validator_coverage.md`.
library;

import 'package:json5_ast/ast.dart';

/// One Dart-side diagnostic entry. Mirrors the path-keyed shape that
/// `TraceStore._validationErrors / _validationWarnings / _validationInfo`
/// expects so the caller can merge these into the same buckets that hold
/// `bxp-fmt --config` output.
class DartDiagnostic {
  /// Path segments from config root (no leading "config."). Used as the
  /// outer key in TraceStore's path-keyed maps after NUL-encoding.
  final List<String> path;

  /// `error` / `warning` / `info` — bucket selector on the consumer side.
  final DartSeverity severity;

  /// Stable code (e.g. `dart.field.NonEmpty`, `dart.expr.UnknownFunction`).
  /// Always prefixed with `dart.` so consumers can route by source. The
  /// bxp-fmt side uses bare `expr.*` / `field.*` codes; combining the two
  /// in one bucket therefore stays unambiguous.
  final String code;
  final String message;
  final String? suggest;

  /// Optional 0-based offset + length within the offending expression
  /// source. Populated only for expr-level diagnostics where a specific
  /// token span is implicated; null for tree-level checks where the
  /// entire field is the unit.
  final int? offset;
  final int? length;

  const DartDiagnostic({
    required this.path,
    required this.severity,
    required this.code,
    required this.message,
    this.suggest,
    this.offset,
    this.length,
  });
}

enum DartSeverity { error, warning, info }

/// Result of validating one expression. The walker emits at most one
/// diagnostic for the first failure encountered (mirroring bxp-fmt
/// `validateExpr` semantics) plus optional offset/length so the caller
/// can underline the offending token in the editor.
class ExprDiagnostic {
  final DartSeverity severity;
  final String code;
  final String message;
  final String? suggest;
  final int? offset;
  final int? length;
  const ExprDiagnostic({
    required this.severity,
    required this.code,
    required this.message,
    this.suggest,
    this.offset,
    this.length,
  });
}

/// CSV headers cached from the most recent dry-run, keyed by template
/// id. Empty / absent entry = no headers known yet for that template
/// (autocomplete falls back to function/keyword-only suggestions).
typedef CsvHeadersByTemplate = Map<String, Set<String>>;

class DartValidator {
  /// Snapshot of the docs catalog at construction time. The validator
  /// does not auto-refresh; callers that want catalog hot-reload should
  /// rebuild the validator. This keeps the per-validate path cheap.
  final Map<String, dynamic> docs;

  /// CSV headers cached per template (from `file_start` events of the
  /// latest dry-run). Used by the `[Field]` cluster-outlier check at
  /// expr level when a template has freshly-known headers; tree-level
  /// checks ignore it.
  final CsvHeadersByTemplate csvHeadersByTemplate;

  DartValidator(this.docs, {this.csvHeadersByTemplate = const {}});

  // ── Cached catalog views (computed once per validator) ────────────────

  late final List<Map<String, dynamic>> _functions =
      ((docs['functions'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  late final List<Map<String, dynamic>> _configSchema =
      ((docs['config_schema'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  /// Function name → FnDoc map for O(1) lookups during expr validation.
  late final Map<String, Map<String, dynamic>> _fnByName = {
    for (final f in _functions)
      (f['name']?.toString() ?? '').toUpperCase(): f,
  };

  /// Set of all builtin function names (uppercase) for unknown-function
  /// detection + Levenshtein nearest-neighbour search.
  late final Set<String> _functionNames = _fnByName.keys.toSet();

  // ── Public entry points ───────────────────────────────────────────────

  /// Walk the full AST and return tree-level + expression-level
  /// diagnostics. The caller is expected to merge them into the same
  /// path-keyed maps that hold bxp-fmt diagnostics — `DartDiagnostic.code`
  /// is `dart.*`-prefixed so the two never collide.
  List<DartDiagnostic> validate(JsonAstNode root) {
    final out = <DartDiagnostic>[];
    _walk(root, const [], out);
    _crossRefs(root, out);
    return out;
  }

  /// Validate a single expression in the context of the current AST and
  /// active template. Returns null when the expression looks clean.
  ///
  /// Used by the inline ExprEditor / ExprPanel for per-keystroke
  /// feedback that doesn't pay the bxp-fmt subprocess cost. Syntax /
  /// precedence errors (UnexpectedToken, ExpectedRParen, ...) still
  /// require the subprocess fallback — Dart-side covers UnknownFunction,
  /// WrongArgCount, the FnArgDoc-driven specialised arg checks, and
  /// LOOKUP pre_pass-name resolution.
  ExprDiagnostic? validateExpr(
    String src, {
    required JsonAstNode root,
    String? activeTemplateId,
  }) {
    if (src.trim().isEmpty) return null;
    final tokens = _tokenize(src);
    final calls = _findCalls(tokens);

    // Pre_pass names declared in the active template (for LOOKUP arg[0]
    // resolution). Empty when no pre_pass block exists or template
    // can't be resolved.
    final prePassNames = activeTemplateId == null
        ? <String>{}
        : _prePassNamesFor(root, activeTemplateId);

    for (final call in calls) {
      final hit = _checkCall(call, src, tokens, prePassNames);
      if (hit != null) return hit;
    }
    return null;
  }

  // ── Tree walker ───────────────────────────────────────────────────────

  void _walk(JsonAstNode node, List<String> path, List<DartDiagnostic> out) {
    if (node is JsonObject) {
      for (final p in node.properties) {
        if (p is JsonProperty) {
          _walk(p.value, [...path, p.key], out);
        }
      }
      _checkUnknownKeys(node, path, out);
    } else if (node is JsonArray) {
      for (var i = 0; i < node.elements.length; i++) {
        final e = node.elements[i];
        if (e is CommentLine) continue;
        _walk(e, [...path, i.toString()], out);
      }
    } else {
      // Scalar — apply per-leaf FieldValidator if FieldDoc declares one.
      _checkLeafValidator(node, path, out);
    }
  }

  void _checkLeafValidator(
      JsonAstNode node, List<String> path, List<DartDiagnostic> out) {
    final doc = _findSchemaDoc(path);
    if (doc == null) return;
    final validator = doc['validator']?.toString() ?? 'none';

    final value = node is JsonString ? node.value : null;

    switch (validator) {
      case 'non_empty':
        if (value != null && value.trim().isEmpty) {
          out.add(DartDiagnostic(
            path: path,
            severity: DartSeverity.error,
            code: 'dart.field.NonEmpty',
            message: 'value cannot be empty',
          ));
        }
        break;
      case 'starts_with_dollar':
        if (value != null && value.isNotEmpty && !value.startsWith(r'$')) {
          out.add(DartDiagnostic(
            path: path,
            severity: DartSeverity.error,
            code: 'dart.field.StartsWithDollar',
            message: 'must start with \$ — references an input_schema variable',
          ));
        }
        break;
      case 'expr_string':
        // Route to expr validator. The active template id is the second
        // path segment when the field sits inside conversion_templates.*.
        if (value != null && value.isNotEmpty) {
          final templateId = (path.length >= 2 &&
                  path[0] == 'conversion_templates')
              ? path[1]
              : null;
          // The walk() caller passed the synthetic root via _walk's
          // outermost frame; we re-fetch it indirectly by leaving the
          // root resolution to the tree-walk caller. Phase 3 wiring
          // passes the AST root to `validate()`, then this validator
          // captures it via closure if needed. Today expr checks here
          // do not consult the root cross-template (LOOKUP pre_pass
          // names are resolved per-template in _crossRefs); a static
          // expr error from the FnArgDoc-driven walker is template-
          // independent and safe to emit here without root.
          final ed = _validateExprStandalone(value);
          if (ed != null) {
            out.add(DartDiagnostic(
              path: path,
              severity: ed.severity,
              code: ed.code,
              message: ed.message,
              suggest: ed.suggest,
              offset: ed.offset,
              length: ed.length,
            ));
          }
          // Intentionally unused — kept to clarify intent for readers
          // following the path → templateId derivation.
          (templateId);
        }
        break;
      case 'none':
      default:
        break;
    }
  }

  /// Standalone expression check that does not need the root AST (no
  /// LOOKUP pre_pass-name resolution). Used during tree walk where the
  /// per-template pre_pass set is folded in by `_crossRefs` afterwards.
  ExprDiagnostic? _validateExprStandalone(String src) {
    final tokens = _tokenize(src);
    final calls = _findCalls(tokens);
    for (final call in calls) {
      final hit = _checkCall(call, src, tokens, const <String>{});
      if (hit != null && hit.code != 'dart.expr.LookupUnknownPrePass') {
        return hit;
      }
    }
    return null;
  }

  void _checkUnknownKeys(
      JsonObject obj, List<String> path, List<DartDiagnostic> out) {
    // Build the set of valid child keys at this path from the schema
    // catalog. If any child entry uses a `*` wildcard, EVERY key is
    // valid — skip the check entirely (free-form map).
    final validKeys = <String>{};
    var hasWildcard = false;
    for (final f in _configSchema) {
      final pattern = f['key']?.toString() ?? '';
      final segs = pattern.split('.');
      if (segs.length != path.length + 1) continue;
      var ok = true;
      for (var i = 0; i < path.length; i++) {
        if (segs[i] == '*') continue;
        if (segs[i] != path[i]) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      final last = segs.last;
      if (last == '*') {
        hasWildcard = true;
        break;
      }
      validKeys.add(last);
    }
    if (hasWildcard || validKeys.isEmpty) return;

    for (final p in obj.properties) {
      if (p is! JsonProperty) continue;
      if (validKeys.contains(p.key)) continue;
      // Skip annotation keys emitted by bxp-fmt — they live alongside
      // real keys in `--config` output but shouldn't be flagged here.
      if (p.key.startsWith(r'$err_') ||
          p.key.startsWith(r'$warn_') ||
          p.key.startsWith(r'$info_') ||
          p.key.startsWith(r'$comm_')) {
        continue;
      }
      final suggest = _closestKey(p.key, validKeys);
      // Severity mirrors `bxp-core`'s post-promotion contract for
      // `validateUnknownKeysCollect` (warning → error after the
      // long-term promotion landed alongside SplitPartBadIndex). Same
      // bucket as bxp-fmt's `$err_*` so json_tree's existing leaf-level
      // error rendering picks it up without a separate warning path.
      // Wording is byte-identical to bxp-core's emit so that when both
      // validators flag the same key (live edit + saved file), the
      // banner-merge path treats them as one message instead of
      // showing two near-duplicate rows.
      final message = suggest == null
          ? "unknown config key '${p.key}' — typo or extraneous entry"
          : "unknown config key '${p.key}' — did you mean '$suggest'?";
      // Note: `suggest` is intentionally null here so the
      // TraceStore-side displayable string doesn't double-append the
      // hint that's already part of `message`. The same wording is
      // emitted by `bxp-core/src/config.zig::validateUnknownKeysCollect`
      // so the merge path collapses the two rows into one.
      out.add(DartDiagnostic(
        path: [...path, p.key],
        severity: DartSeverity.error,
        code: 'dart.config.UnknownKey',
        message: message,
      ));
    }
  }

  // ── Cross-references (unused pre_pass / unused $vars) ─────────────────

  void _crossRefs(JsonAstNode root, List<DartDiagnostic> out) {
    if (root is! JsonObject) return;
    final templates = _findChild(root, 'conversion_templates');
    if (templates is! JsonObject) return;
    for (final p in templates.properties) {
      if (p is! JsonProperty) continue;
      final tid = p.key;
      final template = p.value;
      if (template is! JsonObject) continue;
      _crossRefsInTemplate(tid, template, out);
    }
  }

  void _crossRefsInTemplate(
      String tid, JsonObject template, List<DartDiagnostic> out) {
    final inputSchema = _findChild(template, 'input_schema');
    final prePass = _findChild(template, 'pre_pass');
    final rowRules = _findChild(template, 'row_rules');
    final outputSchema = _findChild(template, 'output_schema');

    // Set of declared $vars — keys of input_schema (must start with $).
    final declaredVars = <String>{};
    if (inputSchema is JsonObject) {
      for (final p in inputSchema.properties) {
        if (p is JsonProperty && p.key.startsWith(r'$')) {
          declaredVars.add(p.key);
        }
      }
    }

    // Set of declared pre_pass block names. Two shapes:
    //   - legacy single-block (when/key/values directly inside pre_pass)
    //     → synthesise "_default"
    //   - named blocks (each child object has when/key/values)
    final prePassNames = <String>{};
    if (prePass is JsonObject) {
      final hasLegacy = prePass.properties.any(
          (e) => e is JsonProperty && (e.key == 'when' || e.key == 'key'));
      if (hasLegacy) {
        prePassNames.add('_default');
      } else {
        for (final p in prePass.properties) {
          if (p is JsonProperty) prePassNames.add(p.key);
        }
      }
    }

    // Walk every expression in the template, gathering referenced
    // $vars + LOOKUP names + [Field] references for the cluster check.
    final usedVars = <String>{};
    final usedPrePass = <String>{};
    var hasComputedLookupName = false;
    var hasTwoArgLookup = false;
    final fieldRefs = <String>[];

    void collect(String src) {
      if (src.isEmpty) return;
      final toks = _tokenize(src);
      for (final t in toks) {
        if (t.kind == _TokKind.variable) {
          usedVars.add(t.text);
        } else if (t.kind == _TokKind.field) {
          // Strip leading [ and trailing ]
          final inner = t.text.substring(1, t.text.length - 1);
          if (inner.isNotEmpty && !_isDigit(inner.codeUnitAt(0))) {
            fieldRefs.add(inner);
          }
        }
      }
      // LOOKUP scan — must reach every call regardless of nesting,
      // because anycoin-style configs embed `LOOKUP(...)` inside
      // `IF(..., ..., LOOKUP(...) / ...)`. `_findCalls` is linear and
      // would skip the inner LOOKUP after consuming the outer IF's
      // tokens. Walk the flat token list looking for LOOKUP+lparen
      // pairs at any depth and scan each call's args independently.
      for (var i = 0; i < toks.length - 1; i++) {
        final t = toks[i];
        if (t.kind != _TokKind.ident) continue;
        if (t.text.toUpperCase() != 'LOOKUP') continue;
        if (toks[i + 1].kind != _TokKind.lparen) continue;
        // Walk this LOOKUP call's args (top-level commas at depth 1).
        var j = i + 2;
        var depth = 1;
        var arg = <_Tok>[];
        final args = <List<_Tok>>[];
        while (j < toks.length && depth > 0) {
          final tt = toks[j];
          if (tt.kind == _TokKind.lparen) {
            depth++;
            arg.add(tt);
          } else if (tt.kind == _TokKind.rparen) {
            depth--;
            if (depth == 0) {
              if (arg.isNotEmpty || args.isNotEmpty) args.add(arg);
              break;
            }
            arg.add(tt);
          } else if (tt.kind == _TokKind.comma && depth == 1) {
            args.add(arg);
            arg = <_Tok>[];
          } else {
            arg.add(tt);
          }
          j++;
        }
        if (args.length == 2) {
          hasTwoArgLookup = true;
        } else if (args.length >= 3) {
          final first = args[0];
          if (first.length == 1 && first.first.kind == _TokKind.string) {
            final name = _unquoteSingle(first.first.text);
            usedPrePass.add(name);
          } else {
            hasComputedLookupName = true;
          }
        }
      }
    }

    void collectFromAny(JsonAstNode? n) {
      if (n == null) return;
      if (n is JsonString) {
        collect(n.value);
        return;
      }
      if (n is JsonObject) {
        for (final p in n.properties) {
          if (p is! JsonProperty) continue;
          collectFromAny(p.value);
        }
        return;
      }
      if (n is JsonArray) {
        for (final e in n.elements) {
          if (e is CommentLine) continue;
          collectFromAny(e);
        }
        return;
      }
    }

    collectFromAny(inputSchema);
    collectFromAny(rowRules);
    collectFromAny(outputSchema);
    collectFromAny(prePass);

    // output_schema values (`"$variable"` strings) reference $vars.
    if (outputSchema is JsonObject) {
      for (final p in outputSchema.properties) {
        if (p is JsonProperty && p.value is JsonString) {
          final v = (p.value as JsonString).value;
          if (v.startsWith(r'$')) usedVars.add(v);
        }
      }
    }

    // Unused $vars warning. Skip vars that are referenced via output_schema
    // or any expression string in the template.
    for (final v in declaredVars) {
      if (usedVars.contains(v)) continue;
      out.add(DartDiagnostic(
        path: ['conversion_templates', tid, 'input_schema', v],
        severity: DartSeverity.warning,
        code: 'dart.config.UnusedVar',
        message: 'variable $v is declared but never referenced',
      ));
    }

    // Unused pre_pass block warning. Skip when any expression contains a
    // computed-name LOOKUP (we can't statically prove which block is
    // hit). For 2-arg LOOKUP with a single declared block, mark that
    // block as used automatically.
    if (!hasComputedLookupName) {
      if (hasTwoArgLookup && prePassNames.length == 1) {
        usedPrePass.add(prePassNames.first);
      }
      for (final n in prePassNames) {
        if (usedPrePass.contains(n)) continue;
        final pPath = n == '_default'
            ? ['conversion_templates', tid, 'pre_pass']
            : ['conversion_templates', tid, 'pre_pass', n];
        out.add(DartDiagnostic(
          path: pPath,
          severity: DartSeverity.warning,
          code: 'dart.config.UnusedPrePass',
          message: "pre_pass block '$n' is declared but never referenced by LOOKUP",
        ));
      }
    }

    // [Field] cluster outlier (G2 layer B-equivalent). One reference at
    // freq==1 vs another at freq>=3 with edit distance ≤ 2.
    final outlier = _clusterOutlier(fieldRefs);
    if (outlier != null) {
      out.add(DartDiagnostic(
        path: ['conversion_templates', tid, 'input_schema'],
        severity: DartSeverity.warning,
        code: 'dart.expr.UnknownField',
        message:
            "field '${outlier.bad}' is referenced once but '${outlier.suggest}' is used many times — possible typo",
        suggest: "did you mean '${outlier.suggest}'?",
      ));
    }
  }

  // ── Expression call-structure walker ──────────────────────────────────

  ExprDiagnostic? _checkCall(
    _Call call,
    String src,
    List<_Tok> tokens,
    Set<String> prePassNames,
  ) {
    final upper = call.name.toUpperCase();
    final fn = _fnByName[upper];

    // UnknownFunction — name not in catalog.
    if (fn == null) {
      final suggest = _closestKey(upper, _functionNames);
      return ExprDiagnostic(
        severity: DartSeverity.error,
        code: 'dart.expr.UnknownFunction',
        message: "unknown function '${call.name}'",
        suggest: suggest == null ? null : "did you mean '$suggest'?",
        offset: call.nameOffset,
        length: call.nameLength,
      );
    }

    final minArgs = (fn['min_args'] as num?)?.toInt() ?? 0;
    final maxArgs = (fn['max_args'] as num?)?.toInt() ?? 0;
    if (minArgs > 0 && call.args.length < minArgs) {
      return ExprDiagnostic(
        severity: DartSeverity.error,
        code: 'dart.expr.WrongArgCount',
        message:
            "${call.name} expects at least $minArgs argument${minArgs == 1 ? '' : 's'}, got ${call.args.length}",
        offset: call.nameOffset,
        length: call.nameLength,
      );
    }
    if (maxArgs > 0 && maxArgs < 255 && call.args.length > maxArgs) {
      return ExprDiagnostic(
        severity: DartSeverity.error,
        code: 'dart.expr.WrongArgCount',
        message:
            "${call.name} expects at most $maxArgs argument${maxArgs == 1 ? '' : 's'}, got ${call.args.length}",
        offset: call.nameOffset,
        length: call.nameLength,
      );
    }

    // Per-arg ArgKind checks. Mirrors the Zig staticCheckCalls walker:
    // single-bare-token gate, first-hit semantics. Variadic positions
    // beyond declared args are ignored (COALESCE).
    final fnArgs = ((fn['args'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    for (var i = 0; i < call.args.length && i < fnArgs.length; i++) {
      final kind = fnArgs[i]['kind']?.toString() ?? 'expr';
      final argTokens = call.args[i];
      // Skip multi-token args (variables, expressions, nested calls)
      // — those are runtime-resolved.
      if (argTokens.length != 1) continue;
      final t = argTokens.first;
      switch (kind) {
        case 'literal_int_positive':
          if (t.kind != _TokKind.number) continue;
          final v = int.tryParse(t.text);
          if (v == null) continue;
          if (v <= 0) {
            return ExprDiagnostic(
              severity: DartSeverity.error,
              code: 'dart.expr.SplitPartBadIndex',
              message:
                  "${call.name} index is 1-based; literal $v always returns \"\"",
              offset: t.offset,
              length: t.text.length,
            );
          }
          break;
        case 'sunrise_format':
          if (t.kind != _TokKind.string) continue;
          final inner = _unquoteSingle(t.text);
          final pos = _scanDateFormat(inner);
          if (pos != null) {
            return ExprDiagnostic(
              severity: DartSeverity.error,
              code: 'dart.expr.DateFormatBadToken',
              message:
                  "${call.name} format '$inner' has unrecognized letter '${inner[pos]}' at offset $pos — wrap any literal letters in brackets, e.g. '[T]'",
              offset: t.offset,
              length: t.text.length,
            );
          }
          break;
        case 'pre_pass_name':
          if (t.kind != _TokKind.string) continue;
          if (prePassNames.isEmpty) continue;
          final name = _unquoteSingle(t.text);
          if (!prePassNames.contains(name)) {
            final suggest = _closestKey(name, prePassNames);
            return ExprDiagnostic(
              severity: DartSeverity.error,
              code: 'dart.expr.LookupUnknownPrePass',
              message: "unknown pre_pass '$name' — check pre_passes block name",
              suggest: suggest == null ? null : "did you mean '$suggest'?",
              offset: t.offset,
              length: t.text.length,
            );
          }
          break;
      }
    }
    return null;
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  Map<String, dynamic>? _findSchemaDoc(List<String> path) {
    if (path.isEmpty) return null;
    for (final f in _configSchema) {
      final pattern = f['key']?.toString() ?? '';
      final segs = pattern.split('.');
      if (segs.length != path.length) continue;
      var ok = true;
      for (var i = 0; i < segs.length; i++) {
        if (segs[i] == '*') continue;
        if (segs[i] != path[i]) {
          ok = false;
          break;
        }
      }
      if (ok) return f;
    }
    return null;
  }

  Set<String> _prePassNamesFor(JsonAstNode root, String tid) {
    final out = <String>{};
    if (root is! JsonObject) return out;
    final templates = _findChild(root, 'conversion_templates');
    if (templates is! JsonObject) return out;
    final t = _findChild(templates, tid);
    if (t is! JsonObject) return out;
    final prePass = _findChild(t, 'pre_pass');
    if (prePass is! JsonObject) return out;
    final hasLegacy = prePass.properties.any(
        (e) => e is JsonProperty && (e.key == 'when' || e.key == 'key'));
    if (hasLegacy) {
      out.add('_default');
    } else {
      for (final p in prePass.properties) {
        if (p is JsonProperty) out.add(p.key);
      }
    }
    return out;
  }

  static JsonAstNode? _findChild(JsonObject obj, String key) {
    for (final p in obj.properties) {
      if (p is JsonProperty && p.key == key) return p.value;
    }
    return null;
  }

  /// Levenshtein nearest-neighbour over [candidates], case-insensitive.
  /// Returns null when no candidate is within edit distance ≤ 2.
  static String? _closestKey(String name, Iterable<String> candidates) {
    String? best;
    var bestDist = 1 << 30;
    final lower = name.toLowerCase();
    for (final c in candidates) {
      final d = _levenshtein(lower, c.toLowerCase());
      if (d < bestDist) {
        bestDist = d;
        best = c;
      }
    }
    if (bestDist > 2) return null;
    return best;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final n = a.length;
    final m = b.length;
    var prev = List<int>.generate(m + 1, (i) => i);
    var curr = List<int>.filled(m + 1, 0);
    for (var i = 1; i <= n; i++) {
      curr[0] = i;
      for (var j = 1; j <= m; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        var val = prev[j] + 1;
        if (curr[j - 1] + 1 < val) val = curr[j - 1] + 1;
        if (prev[j - 1] + cost < val) val = prev[j - 1] + cost;
        curr[j] = val;
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[m];
  }

  /// Mirror of `bxp-core/src/expr.zig::scanDateFormat` (sunrise vocabulary
  /// `Y M D E A / a e h i m s`). Returns the 0-based offset of the first
  /// out-of-vocabulary letter outside `[...]` brackets, or null when the
  /// string is clean.
  static int? _scanDateFormat(String fmt) {
    var i = 0;
    while (i < fmt.length) {
      final c = fmt.codeUnitAt(i);
      if (c == 0x5B /* [ */) {
        i++;
        while (i < fmt.length && fmt.codeUnitAt(i) != 0x5D /* ] */) {
          i++;
        }
        i++;
        continue;
      }
      const allowed = {
        0x41, 0x44, 0x45, 0x4D, 0x59, // A D E M Y
        0x61, 0x65, 0x68, 0x69, 0x6D, 0x73, // a e h i m s
      };
      final isUpper = c >= 0x41 && c <= 0x5A;
      final isLower = c >= 0x61 && c <= 0x7A;
      if ((isUpper || isLower) && !allowed.contains(c)) return i;
      i++;
    }
    return null;
  }

  /// Frequency-cluster outlier detection. Mirrors the Zig
  /// `staticCheckFieldClustering` heuristic: bad = freq 1, suggest =
  /// nearest freq>=3 with edit distance ≤ 2. Returns null when no such
  /// pair exists.
  static _Outlier? _clusterOutlier(List<String> refs) {
    final freq = <String, int>{};
    for (final r in refs) {
      freq[r] = (freq[r] ?? 0) + 1;
    }
    final highs = freq.entries.where((e) => e.value >= 3).map((e) => e.key);
    for (final entry in freq.entries) {
      if (entry.value != 1) continue;
      final suggest = _closestKey(entry.key, highs);
      if (suggest != null && suggest != entry.key) {
        return _Outlier(entry.key, suggest);
      }
    }
    return null;
  }

  static String _unquoteSingle(String src) {
    if (src.length >= 2 && src.codeUnitAt(0) == 0x27 /* ' */) {
      return src.substring(1, src.length - 1);
    }
    return src;
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  // ── Mini expression tokenizer ─────────────────────────────────────────
  //
  // Mirrors the regex tokenizer in `expr_highlight.dart` but keeps
  // offsets/lengths so call-structure can be reported back with span
  // info. Not a full bxp expression parser — sufficient to identify
  // ident, parens, commas, strings, numbers, field/var references at
  // the depth needed for FnArgDoc-driven static checks.

  static List<_Tok> _tokenize(String src) {
    final out = <_Tok>[];
    var i = 0;
    while (i < src.length) {
      final c = src.codeUnitAt(i);
      // Whitespace
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        i++;
        continue;
      }
      // [ColumnName]
      if (c == 0x5B) {
        final start = i;
        i++;
        while (i < src.length && src.codeUnitAt(i) != 0x5D) {
          i++;
        }
        if (i < src.length) i++;
        out.add(_Tok(_TokKind.field, src.substring(start, i), start));
        continue;
      }
      // $variable
      if (c == 0x24) {
        final start = i;
        i++;
        while (i < src.length && _isIdentChar(src.codeUnitAt(i))) {
          i++;
        }
        out.add(_Tok(_TokKind.variable, src.substring(start, i), start));
        continue;
      }
      // 'string' — bxp expr syntax has TWO single-quote forms:
      //   - `'''` (three single quotes) is a SPECIAL token: placeholder
      //     for csv_text_quote_out. Tokenized as a single string-kind
      //     token of length 3 so the surrounding `[Field]` references
      //     don't get swallowed (typical xtb1/xtb2 `$comment`:
      //     `''' & [Field] & '''`).
      //   - Otherwise, a normal `'...'` literal — scan to the next
      //     unescaped `'`. Backslash `\` escapes the following char.
      // No CSV-style `''` doubling exists; that interpretation would
      // break the triple-quote placeholder.
      if (c == 0x27) {
        // Triple-quote placeholder: three consecutive `'`.
        if (i + 2 < src.length &&
            src.codeUnitAt(i + 1) == 0x27 &&
            src.codeUnitAt(i + 2) == 0x27) {
          out.add(_Tok(_TokKind.string, "'''", i));
          i += 3;
          continue;
        }
        final start = i;
        i++;
        while (i < src.length) {
          final cc = src.codeUnitAt(i);
          if (cc == 0x5C) {
            i += 2;
            continue;
          }
          if (cc == 0x27) {
            i++;
            break;
          }
          i++;
        }
        out.add(_Tok(_TokKind.string, src.substring(start, i), start));
        continue;
      }
      // number (incl. leading -)
      if (_isDigit(c) ||
          (c == 0x2D /* - */ && i + 1 < src.length && _isDigit(src.codeUnitAt(i + 1)))) {
        final start = i;
        if (c == 0x2D) i++;
        while (i < src.length && (_isDigit(src.codeUnitAt(i)) || src.codeUnitAt(i) == 0x2E /* . */)) {
          i++;
        }
        out.add(_Tok(_TokKind.number, src.substring(start, i), start));
        continue;
      }
      // ( ) ,
      if (c == 0x28) {
        out.add(_Tok(_TokKind.lparen, '(', i));
        i++;
        continue;
      }
      if (c == 0x29) {
        out.add(_Tok(_TokKind.rparen, ')', i));
        i++;
        continue;
      }
      if (c == 0x2C) {
        out.add(_Tok(_TokKind.comma, ',', i));
        i++;
        continue;
      }
      // operators (single char): + - * / & = < > !
      if (c == 0x2B || c == 0x2D || c == 0x2A || c == 0x2F ||
          c == 0x26 || c == 0x3D || c == 0x3C || c == 0x3E || c == 0x21) {
        // 2-char operators (<=, >=, !=) — peek ahead.
        if (i + 1 < src.length && src.codeUnitAt(i + 1) == 0x3D &&
            (c == 0x3C || c == 0x3E || c == 0x21)) {
          out.add(_Tok(_TokKind.op, src.substring(i, i + 2), i));
          i += 2;
          continue;
        }
        out.add(_Tok(_TokKind.op, src.substring(i, i + 1), i));
        i++;
        continue;
      }
      // ident
      if (_isIdentStart(c)) {
        final start = i;
        while (i < src.length && _isIdentChar(src.codeUnitAt(i))) {
          i++;
        }
        out.add(_Tok(_TokKind.ident, src.substring(start, i), start));
        continue;
      }
      // Unknown — advance by one to make progress.
      i++;
    }
    return out;
  }

  static bool _isIdentStart(int c) =>
      (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;
  static bool _isIdentChar(int c) =>
      _isIdentStart(c) || _isDigit(c);

  /// Walk a flat token list, identify call sites (`ident '(' ... ')'`),
  /// and split top-level args by commas. Nested parens raise depth and
  /// their inner tokens belong to the enclosing arg verbatim — this
  /// matches the Zig `staticCheckCalls` walker semantics. Returns one
  /// _Call entry per top-level `ident '('` occurrence; nested calls
  /// inside an outer arg are NOT re-scanned (preserved limitation).
  static List<_Call> _findCalls(List<_Tok> tokens) {
    final out = <_Call>[];
    var i = 0;
    while (i < tokens.length) {
      final t = tokens[i];
      if (t.kind != _TokKind.ident) {
        i++;
        continue;
      }
      if (i + 1 >= tokens.length || tokens[i + 1].kind != _TokKind.lparen) {
        i++;
        continue;
      }
      final name = t.text;
      final nameOffset = t.offset;
      final nameLength = t.text.length;
      i += 2; // consume ident + lparen
      var depth = 1;
      var arg = <_Tok>[];
      final args = <List<_Tok>>[];
      while (i < tokens.length && depth > 0) {
        final tt = tokens[i];
        if (tt.kind == _TokKind.lparen) {
          depth++;
          arg.add(tt);
        } else if (tt.kind == _TokKind.rparen) {
          depth--;
          if (depth == 0) {
            if (arg.isNotEmpty || args.isNotEmpty) args.add(arg);
            i++;
            break;
          }
          arg.add(tt);
        } else if (tt.kind == _TokKind.comma && depth == 1) {
          args.add(arg);
          arg = <_Tok>[];
        } else {
          arg.add(tt);
        }
        i++;
      }
      out.add(_Call(name, nameOffset, nameLength, args));
    }
    return out;
  }
}

// ── Internal types ──────────────────────────────────────────────────────

enum _TokKind { ident, field, variable, string, number, op, lparen, rparen, comma }

class _Tok {
  final _TokKind kind;
  final String text;
  final int offset;
  const _Tok(this.kind, this.text, this.offset);
}

class _Call {
  final String name;
  final int nameOffset;
  final int nameLength;
  final List<List<_Tok>> args;
  const _Call(this.name, this.nameOffset, this.nameLength, this.args);
}

class _Outlier {
  final String bad;
  final String suggest;
  const _Outlier(this.bad, this.suggest);
}
