import { useEffect, useRef } from "react";
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, lineNumbers } from "@codemirror/view";
import { history, historyKeymap, defaultKeymap } from "@codemirror/commands";
import {
	bracketMatching,
	indentOnInput,
	foldKeymap,
} from "@codemirror/language";
import {
	autocompletion,
	closeBrackets,
	closeBracketsKeymap,
	completionKeymap,
} from "@codemirror/autocomplete";
import { setDiagnostics, type Diagnostic } from "@codemirror/lint";
import { bxpExpr } from "../expr/language";

type Props = {
	value: string;
	onChange?: (v: string) => void;
	readOnly?: boolean;
	height?: number | string;
	marker?: string | null;
};

const baseTheme = EditorView.theme(
	{
		"&": {
			color: "#e2e8f0",
			backgroundColor: "#0f172a",
			fontSize: "13px",
			fontFamily:
				"ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
			height: "100%",
		},
		".cm-content": { caretColor: "#e2e8f0", padding: "6px 0" },
		".cm-cursor, .cm-dropCursor": { borderLeftColor: "#e2e8f0" },
		"&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection":
			{ backgroundColor: "#1e293b" },
		".cm-gutters": {
			backgroundColor: "#0f172a",
			color: "#475569",
			border: "none",
		},
		".cm-activeLine": { backgroundColor: "transparent" },
		".cm-activeLineGutter": { backgroundColor: "transparent" },
		".cm-tooltip": {
			backgroundColor: "#1e293b",
			border: "1px solid #334155",
			color: "#e2e8f0",
			borderRadius: "4px",
		},
		".cm-tooltip-autocomplete > ul > li": { color: "#cbd5e1" },
		".cm-tooltip-autocomplete > ul > li[aria-selected]": {
			backgroundColor: "#334155",
			color: "#f1f5f9",
		},
		".cm-tooltip.cm-tooltip-lint": { maxWidth: "40ch" },
		".cm-diagnostic-error": { borderLeftColor: "#ef4444" },
	},
	{ dark: true },
);

export function ExprEditor({
	value,
	onChange,
	readOnly = false,
	height = 80,
	marker = null,
}: Props) {
	const containerRef = useRef<HTMLDivElement | null>(null);
	const viewRef = useRef<EditorView | null>(null);
	// Compartments let us reconfigure a single facet (readOnly) without
	// recreating the whole EditorState.
	const readOnlyCompartment = useRef(new Compartment());

	useEffect(() => {
		if (!containerRef.current) return;
		const state = EditorState.create({
			doc: value,
			extensions: [
				lineNumbers({ formatNumber: () => "" }), // just the gutter gap, no numbers
				history(),
				indentOnInput(),
				bracketMatching(),
				closeBrackets(),
				autocompletion(),
				bxpExpr(),
				baseTheme,
				keymap.of([
					...closeBracketsKeymap,
					...defaultKeymap,
					...historyKeymap,
					...foldKeymap,
					...completionKeymap,
				]),
				EditorView.lineWrapping,
				EditorView.updateListener.of((u) => {
					if (u.docChanged) onChange?.(u.state.doc.toString());
				}),
				readOnlyCompartment.current.of(EditorState.readOnly.of(readOnly)),
			],
		});
		const view = new EditorView({
			state,
			parent: containerRef.current,
		});
		viewRef.current = view;
		return () => {
			view.destroy();
			viewRef.current = null;
		};
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, []);

	// Sync external `value` changes (e.g. example-picker buttons).
	useEffect(() => {
		const view = viewRef.current;
		if (!view) return;
		const current = view.state.doc.toString();
		if (current === value) return;
		view.dispatch({
			changes: { from: 0, to: current.length, insert: value },
		});
	}, [value]);

	// Toggle read-only without rebuilding the state.
	useEffect(() => {
		const view = viewRef.current;
		if (!view) return;
		view.dispatch({
			effects: readOnlyCompartment.current.reconfigure(
				EditorState.readOnly.of(readOnly),
			),
		});
	}, [readOnly]);

	// Push validation marker as a CM6 lint diagnostic covering the whole doc.
	useEffect(() => {
		const view = viewRef.current;
		if (!view) return;
		const diagnostics: Diagnostic[] =
			marker && marker.length > 0
				? [
						{
							from: 0,
							to: view.state.doc.length,
							severity: "error",
							message: marker,
						},
					]
				: [];
		view.dispatch(setDiagnostics(view.state, diagnostics));
	}, [marker]);

	return (
		<div
			ref={containerRef}
			style={{ height: typeof height === "number" ? `${height}px` : height }}
			className="border border-slate-800 rounded overflow-hidden bg-slate-950"
		/>
	);
}
