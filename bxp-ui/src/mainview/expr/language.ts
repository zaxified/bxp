import { StreamLanguage, LanguageSupport, HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { autocompletion, type CompletionContext } from "@codemirror/autocomplete";
import { tags as t } from "@lezer/highlight";
import { BXP_FUNCTIONS, FUNCTION_NAMES, BXP_KEYWORDS } from "./catalog";

const FUNCTION_SET = new Set<string>(FUNCTION_NAMES);
const KEYWORD_SET = new Set<string>(BXP_KEYWORDS);

// CM6 StreamLanguage tokenizer. Each call to `token()` advances the stream and
// returns a tag name (as defined in `tokenTable` below) or null for whitespace.
const bxpExprStream = StreamLanguage.define<unknown>({
	name: "bxp-expr",
	token(stream) {
		if (stream.eatSpace()) return null;

		// [ColumnName]
		if (stream.match(/^\[[^\]]*\]/)) return "columnRef";
		// $var
		if (stream.match(/^\$[A-Za-z_][A-Za-z0-9_]*/)) return "inputVar";
		// 'single quoted string'
		if (stream.match(/^'([^'\\]|\\.)*'/)) return "string";
		// numbers
		if (stream.match(/^\d+(\.\d+)?/)) return "number";
		// operators (multi-char first)
		if (stream.match(/^(<=|>=|!=)/)) return "operator";
		if (stream.match(/^[=<>+\-*/&]/)) return "operator";
		// punctuation
		if (stream.match(/^[(),]/)) return "punctuation";
		// identifier — functions vs keywords vs bare identifier
		const idMatch = stream.match(/^[A-Za-z_][A-Za-z0-9_]*/);
		if (idMatch) {
			const word = Array.isArray(idMatch) ? idMatch[0] : stream.current();
			if (FUNCTION_SET.has(word)) return "function";
			if (KEYWORD_SET.has(word)) return "keyword";
			return "identifier";
		}
		stream.next();
		return null;
	},
	tokenTable: {
		columnRef: t.propertyName,
		inputVar: t.variableName,
		string: t.string,
		number: t.number,
		operator: t.operator,
		punctuation: t.punctuation,
		function: t.function(t.variableName),
		keyword: t.keyword,
		identifier: t.name,
	},
});

// Dark highlight style — matches the Tailwind slate palette used elsewhere.
const bxpExprHighlight = HighlightStyle.define([
	{ tag: t.function(t.variableName), color: "#c4b5fd", fontWeight: "600" },
	{ tag: t.keyword, color: "#60a5fa", fontWeight: "600" },
	{ tag: t.propertyName, color: "#fbbf24" },
	{ tag: t.variableName, color: "#f472b6" },
	{ tag: t.string, color: "#6ee7b7" },
	{ tag: t.number, color: "#fcd34d" },
	{ tag: t.operator, color: "#94a3b8" },
	{ tag: t.punctuation, color: "#64748b" },
	{ tag: t.name, color: "#e2e8f0" },
]);

function bxpExprCompletions(ctx: CompletionContext) {
	// Match the word being typed — includes $ so `$va` completes, and letters
	// for function names. Triggered automatically by CM6 when typing a letter
	// or explicitly via Ctrl-Space.
	const word = ctx.matchBefore(/[A-Za-z_$][A-Za-z0-9_]*/);
	if (!word) return null;
	if (word.from === word.to && !ctx.explicit) return null;

	const fnOptions = BXP_FUNCTIONS.map((f) => ({
		label: f.name,
		type: "function",
		detail: f.signature,
		info: f.description,
		apply: `${f.name}()`,
	}));
	const kwOptions = BXP_KEYWORDS.map((k) => ({
		label: k,
		type: "keyword",
	}));
	return {
		from: word.from,
		options: [...fnOptions, ...kwOptions],
	};
}

export function bxpExpr(): LanguageSupport {
	return new LanguageSupport(bxpExprStream, [
		syntaxHighlighting(bxpExprHighlight),
		autocompletion({
			override: [bxpExprCompletions],
			// Popup background should match the editor, not light CM default.
			activateOnTyping: true,
		}),
	]);
}
