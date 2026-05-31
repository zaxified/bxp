// Mermaid block syntax validator.
//
// Extracts ```mermaid``` fenced blocks from each .md file passed on the
// CLI, runs the mermaid core parser against each, and reports parse
// errors with file:line context. Returns exit 1 on any failure.
//
// Used by scripts/check-formatting.sh — keeps mermaid docs from drifting
// into invalid syntax that renders as raw "Parse error on line ..." in
// GitHub previews.

import { readFileSync } from 'node:fs';
import { argv, exit, stderr, stdout } from 'node:process';
import { Window } from 'happy-dom';

// Mermaid's parse() pipes labels through DOMPurify, which requires a
// window/document. Install a lightweight happy-dom global before
// importing mermaid so its sanitizer can attach.
const window = new Window();
globalThis.window = window;
globalThis.document = window.document;
globalThis.DocumentFragment = window.DocumentFragment;
globalThis.Node = window.Node;
globalThis.Element = window.Element;
globalThis.HTMLElement = window.HTMLElement;

const { default: mermaid } = await import('mermaid');
mermaid.initialize({ startOnLoad: false, securityLevel: 'loose' });

const files = argv.slice(2);
if (files.length === 0) {
  stderr.write('usage: check.mjs <file.md> [<file.md> ...]\n');
  exit(2);
}

let totalBlocks = 0;
let totalFailures = 0;

for (const file of files) {
  let src;
  try {
    src = readFileSync(file, 'utf8');
  } catch (e) {
    stderr.write(`${file}: cannot read — ${e.message}\n`);
    totalFailures++;
    continue;
  }

  const lines = src.split('\n');
  let inBlock = false;
  let blockFirstLine = 0; // 1-based line number of the content's first line
  let blockSrc = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!inBlock && /^```mermaid\s*$/.test(line)) {
      inBlock = true;
      blockFirstLine = i + 2; // i is 0-based; +1 for line number, +1 to skip the fence
      blockSrc = [];
      continue;
    }
    if (inBlock && /^```\s*$/.test(line)) {
      inBlock = false;
      totalBlocks++;
      try {
        await mermaid.parse(blockSrc.join('\n'));
      } catch (e) {
        totalFailures++;
        const msg = (e?.message ?? String(e)).trimEnd();
        stderr.write(`${file}:${blockFirstLine}: mermaid parse error\n`);
        for (const ln of msg.split('\n')) stderr.write(`    ${ln}\n`);
      }
      continue;
    }
    if (inBlock) blockSrc.push(line);
  }

  if (inBlock) {
    totalFailures++;
    stderr.write(`${file}:${blockFirstLine}: unterminated \`\`\`mermaid block\n`);
  }
}

stdout.write(`mermaid: ${totalBlocks} block(s) checked, ${totalFailures} failure(s)\n`);
exit(totalFailures === 0 ? 0 : 1);
