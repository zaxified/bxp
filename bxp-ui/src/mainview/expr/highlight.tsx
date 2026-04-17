import { Fragment } from "react";
import { FUNCTION_NAMES, BXP_KEYWORDS } from "./catalog";

const FUNCTION_SET = new Set<string>(FUNCTION_NAMES);
const KEYWORD_SET = new Set<string>(BXP_KEYWORDS);

type Tok =
	| "column"
	| "var"
	| "string"
	| "number"
	| "op"
	| "punct"
	| "function"
	| "keyword"
	| "ident"
	| "ws";

type Span = { kind: Tok; text: string };

// Single-pass tokenizer mirroring src/mainview/expr/language.ts. Returns spans
// for React rendering; kept in sync with the CM6 StreamLanguage regex set.
function tokenize(src: string): Span[] {
	const out: Span[] = [];
	let i = 0;
	while (i < src.length) {
		const rest = src.slice(i);
		const ws = /^\s+/.exec(rest);
		if (ws) {
			out.push({ kind: "ws", text: ws[0] });
			i += ws[0].length;
			continue;
		}
		const col = /^\[[^\]]*\]/.exec(rest);
		if (col) {
			out.push({ kind: "column", text: col[0] });
			i += col[0].length;
			continue;
		}
		const v = /^\$[A-Za-z_][A-Za-z0-9_]*/.exec(rest);
		if (v) {
			out.push({ kind: "var", text: v[0] });
			i += v[0].length;
			continue;
		}
		const str = /^'([^'\\]|\\.)*'/.exec(rest);
		if (str) {
			out.push({ kind: "string", text: str[0] });
			i += str[0].length;
			continue;
		}
		const num = /^\d+(\.\d+)?/.exec(rest);
		if (num) {
			out.push({ kind: "number", text: num[0] });
			i += num[0].length;
			continue;
		}
		const op2 = /^(<=|>=|!=)/.exec(rest);
		if (op2) {
			out.push({ kind: "op", text: op2[0] });
			i += op2[0].length;
			continue;
		}
		const op1 = /^[=<>+\-*/&]/.exec(rest);
		if (op1) {
			out.push({ kind: "op", text: op1[0] });
			i += op1[0].length;
			continue;
		}
		const punct = /^[(),]/.exec(rest);
		if (punct) {
			out.push({ kind: "punct", text: punct[0] });
			i += punct[0].length;
			continue;
		}
		const id = /^[A-Za-z_][A-Za-z0-9_]*/.exec(rest);
		if (id) {
			const word = id[0];
			const kind: Tok = FUNCTION_SET.has(word)
				? "function"
				: KEYWORD_SET.has(word)
					? "keyword"
					: "ident";
			out.push({ kind, text: word });
			i += word.length;
			continue;
		}
		// Unknown single char — render as ident so it's still visible.
		out.push({ kind: "ident", text: src[i] });
		i += 1;
	}
	return out;
}

const CLASS_FOR: Record<Tok, string> = {
	column: "text-amber-400",
	var: "text-pink-400",
	string: "text-emerald-300",
	number: "text-amber-300",
	op: "text-slate-400",
	punct: "text-slate-500",
	function: "text-violet-300 font-semibold",
	keyword: "text-sky-400 font-semibold",
	ident: "text-slate-200",
	ws: "",
};

export function ExprInline({ text }: { text: string }) {
	const spans = tokenize(text);
	return (
		<span className="whitespace-pre-wrap break-all">
			{spans.map((s, idx) => (
				<Fragment key={idx}>
					<span className={CLASS_FOR[s.kind]}>{s.text}</span>
				</Fragment>
			))}
		</span>
	);
}
