import { StreamLanguage, LanguageSupport, HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { autocompletion, type CompletionContext } from "@codemirror/autocomplete";
import { tags as t } from "@lezer/highlight";
import type { FnDoc, KeywordDoc } from "../../shared/types";
import { C } from "./colors";

const bxpExprHighlight = HighlightStyle.define([
	{ tag: t.function(t.variableName), color: C.function,    fontWeight: "600" },
	{ tag: t.keyword,                  color: C.keyword,     fontWeight: "600" },
	{ tag: t.propertyName,             color: C.columnRef },
	{ tag: t.variableName,             color: C.inputVar },
	{ tag: t.string,                   color: C.string },
	{ tag: t.number,                   color: C.number },
	{ tag: t.operator,                 color: C.operator },
	{ tag: t.punctuation,              color: C.punctuation },
	{ tag: t.name,                     color: C.ident },
]);

export function bxpExpr(functions: FnDoc[], keywords: KeywordDoc[]): LanguageSupport {
	const fnSet = new Set(functions.map((f) => f.name));
	const kwSet = new Set(keywords.map((k) => k.name));

	// StreamLanguage is created inside the factory so the token() closure
	// can classify identifiers as function/keyword/ident using the live sets.
	const stream = StreamLanguage.define<unknown>({
		name: "bxp-expr",
		token(s) {
			if (s.eatSpace()) return null;
			if (s.match(/^\[[^\]]*\]/))         return "columnRef";
			if (s.match(/^\$[A-Za-z_][A-Za-z0-9_]*/)) return "inputVar";
			if (s.match(/^'([^'\\]|\\.)*'/))    return "string";
			if (s.match(/^\d+(\.\d+)?/))         return "number";
			if (s.match(/^(<=|>=|!=)/))          return "operator";
			if (s.match(/^[=<>+\-*/&]/))         return "operator";
			if (s.match(/^[(),]/))               return "punctuation";
			const id = s.match(/^[A-Za-z_][A-Za-z0-9_]*/);
			if (id) {
				const word = Array.isArray(id) ? id[0] : s.current();
				if (fnSet.has(word)) return "function";
				if (kwSet.has(word)) return "keyword";
				return "identifier";
			}
			s.next();
			return null;
		},
		tokenTable: {
			columnRef:  t.propertyName,
			inputVar:   t.variableName,
			string:     t.string,
			number:     t.number,
			operator:   t.operator,
			punctuation: t.punctuation,
			function:   t.function(t.variableName),
			keyword:    t.keyword,
			identifier: t.name,
		},
	});

	function completions(ctx: CompletionContext) {
		const word = ctx.matchBefore(/[A-Za-z_$][A-Za-z0-9_]*/);
		if (!word) return null;
		if (word.from === word.to && !ctx.explicit) return null;
		return {
			from: word.from,
			options: [
				...functions.map((f) => ({
					label: f.name,
					type: "function",
					detail: f.signature,
					info: f.description,
					apply: `${f.name}()`,
				})),
				...keywords.map((k) => ({ label: k.name, type: "keyword" })),
			],
		};
	}

	return new LanguageSupport(stream, [
		syntaxHighlighting(bxpExprHighlight),
		autocompletion({ override: [completions], activateOnTyping: true }),
	]);
}
