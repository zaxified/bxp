import 'dart:io';
import 'package:json_ast_proto/parser.dart';
import 'package:json_ast_proto/dumper.dart';
import 'package:json_ast_proto/ast.dart';

void main(List<String> args) {
  final input = args.isNotEmpty
      ? args[0]
      : '/home/zak/workspace/bxp/DEV/bxp-cli.json';
  final output = args.length > 1
      ? args[1]
      : '/home/zak/workspace/bxp/DEV/bxp-cli.json_ast_out';

  final src = File(input).readAsStringSync();
  stderr.writeln('input: $input (${src.length} bytes, ${src.split("\n").length} lines)');

  final t0 = DateTime.now();
  final result = Parser.parse(src);
  final t1 = DateTime.now();

  if (result.diagnostics.isNotEmpty) {
    for (final d in result.diagnostics) {
      stderr.writeln('${d.severity.name.toUpperCase()} ${d.span.startLine}:${d.span.startCol}: ${d.message}');
    }
    if (result.hasErrors) exit(1);
  }
  if (result.root == null) {
    stderr.writeln('ERROR: parser returned null root');
    exit(1);
  }

  final stats = _stats(result.root!);
  stderr.writeln('parsed in ${t1.difference(t0).inMilliseconds}ms');
  stderr.writeln('  objects=${stats.objects} arrays=${stats.arrays} props=${stats.props}');
  stderr.writeln('  strings=${stats.strings} numbers=${stats.numbers} bools=${stats.bools} nulls=${stats.nulls}');
  stderr.writeln('  comments(line)=${stats.commentsLine} comments(block)=${stats.commentsBlock}');
  stderr.writeln('  trailing-comments=${stats.trailingComments}');

  final t2 = DateTime.now();
  final out = Dumper.dump(result.root!);
  final t3 = DateTime.now();

  File(output).writeAsStringSync(out);
  stderr.writeln('dumped in ${t3.difference(t2).inMilliseconds}ms → $output (${out.length} bytes, ${out.split("\n").length} lines)');
}

class _Stats {
  int objects = 0, arrays = 0, props = 0;
  int strings = 0, numbers = 0, bools = 0, nulls = 0;
  int commentsLine = 0, commentsBlock = 0, trailingComments = 0;
}

_Stats _stats(JsonAstNode root) {
  final s = _Stats();
  void visit(JsonAstNode n) {
    if (n is JsonObject) {
      s.objects++;
      for (final p in n.properties) {
        visit(p);
      }
    } else if (n is JsonArray) {
      s.arrays++;
      for (final e in n.elements) {
        visit(e);
      }
    } else if (n is JsonProperty) {
      s.props++;
      visit(n.value);
    } else if (n is JsonString) {
      s.strings++;
    } else if (n is JsonNumber) {
      s.numbers++;
    } else if (n is JsonBool) {
      s.bools++;
    } else if (n is JsonNull) {
      s.nulls++;
    } else if (n is CommentLine) {
      if (n.comment.style == CommentStyle.line) {
        s.commentsLine++;
      } else {
        s.commentsBlock++;
      }
      if (n.inlinePlacement) s.trailingComments++;
    }
  }
  visit(root);
  return s;
}
