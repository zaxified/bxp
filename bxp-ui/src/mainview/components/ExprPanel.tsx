import { useEffect, useState, useMemo } from "react";
import { useTraceStore, type PathSeg } from "../store";
import { ExprEditor } from "./ExprEditor";
import { bxpExpr } from "../expr/language";
import { C } from "../expr/colors";

const TOKEN_STYLE: Record<string, { color: string; fontWeight?: string }> = {
	columnRef: { color: C.columnRef },
	inputVar:  { color: C.inputVar },
	string:    { color: C.string },
	number:    { color: C.number },
	function:  { color: C.function,  fontWeight: "600" },
	keyword:   { color: C.keyword,   fontWeight: "600" },
};

type ValidationState =
	| { kind: "idle" }
	| { kind: "pending" }
	| { kind: "ok" }
	| { kind: "error"; message: string };

export function ExprPanel() {
	const selectedExprPath = useTraceStore((s) => s.selectedExprPath);
	const selectedExprText = useTraceStore((s) => s.selectedExprText);
	const setSelectedExpr = useTraceStore((s) => s.setSelectedExpr);
	const clearSelectedExpr = useTraceStore((s) => s.clearSelectedExpr);
	const editLeaf = useTraceStore((s) => s.editLeaf);
	const validateExpr = useTraceStore((s) => s.validateExpr);
	const docs = useTraceStore((s) => s.docs);

	const [draft, setDraft] = useState(selectedExprText);
	const [state, setState] = useState<ValidationState>({ kind: "idle" });

	// Build CM6 language extension from docs (reconfigured via Compartment when docs load)
	const languageExt = useMemo(
		() => (docs ? bxpExpr(docs.functions, docs.keywords) : null),
		[docs],
	);

	// Sync draft when a new leaf is selected
	useEffect(() => {
		setDraft(selectedExprText);
		setState({ kind: "idle" });
	}, [selectedExprPath, selectedExprText]);

	// Debounced validation
	useEffect(() => {
		if (!selectedExprPath) return;
		if (draft.trim().length === 0) { setState({ kind: "idle" }); return; }
		setState({ kind: "pending" });
		const h = setTimeout(async () => {
			const res = await validateExpr(draft);
			setState(res.ok ? { kind: "ok" } : { kind: "error", message: res.error ?? "unknown error" });
		}, 300);
		return () => clearTimeout(h);
	}, [draft, selectedExprPath, validateExpr]);

	const commit = () => {
		if (selectedExprPath && draft !== selectedExprText) {
			editLeaf(selectedExprPath, draft);
			setSelectedExpr(selectedExprPath, draft);
		}
	};

	return (
		<div className="h-full flex flex-col overflow-hidden">
			{/* Editor section */}
			<div className="shrink-0 border-b border-slate-800 p-3 flex flex-col gap-2">
				{selectedExprPath ? (
					<>
						<div className="flex items-center gap-2">
							<Breadcrumb path={selectedExprPath} />
							<div className="flex-1" />
							<ValidationBadge state={state} />
							<button
								type="button"
								onClick={clearSelectedExpr}
								className="text-[10px] uppercase tracking-wider text-slate-500 hover:text-slate-200 px-1"
								title="Close editor"
							>
								✕
							</button>
						</div>
						<ExprEditor
							value={draft}
							onChange={setDraft}
							onBlur={commit}
							height={240}
							marker={state.kind === "error" ? state.message : null}
							languageExt={languageExt}
						/>
						{state.kind === "error" && (
							<pre className="text-red-400 whitespace-pre-wrap break-all text-[11px] font-mono border border-red-900/40 bg-red-950/20 p-2">
								{state.message}
							</pre>
						)}
					</>
				) : (
					<div className="text-xs text-slate-500 italic py-1">
						Click an expression in the tree to edit it here.
					</div>
				)}
			</div>

			{/* Docs catalog — two columns */}
			<div className="flex-1 min-h-0 overflow-hidden flex">
				{docs ? (
					<>
						{/* Left: functions */}
						<div className="w-1/2 overflow-y-auto p-3 border-r border-slate-800">
							<div className="text-[10px] uppercase tracking-wider text-slate-500 mb-2">Functions</div>
							<ul className="space-y-2 text-xs">
								{docs.functions.map((f) => (
									<li key={f.name} className="font-mono">
										<div style={{ color: C.function, fontWeight: 600 }}>{f.signature}</div>
										<div className="text-slate-400 text-[11px] leading-snug">{f.description}</div>
									</li>
								))}
							</ul>
						</div>

						{/* Right: keywords + operators + tokens */}
						<div className="w-1/2 overflow-y-auto p-3 space-y-4">
							<section>
								<div className="text-[10px] uppercase tracking-wider text-slate-500 mb-2">Keywords</div>
								<ul className="space-y-1 text-xs">
									{docs.keywords.map((k) => (
										<li key={k.name} className="font-mono">
											<span style={{ color: C.keyword, fontWeight: 600 }}>{k.name}</span>
											<span className="text-slate-400 text-[11px] ml-2">{k.description}</span>
										</li>
									))}
								</ul>
							</section>

							<section>
								<div className="text-[10px] uppercase tracking-wider text-slate-500 mb-2">Operators</div>
								<ul className="space-y-1 text-xs font-mono">
									{docs.operators.map((op) => (
										<li key={op.token} className="flex gap-3">
											<span style={{ color: C.operator }} className="w-6 shrink-0">{op.token}</span>
											<span className="text-slate-400 text-[11px]">{op.description}</span>
										</li>
									))}
								</ul>
							</section>

							<section>
								<div className="text-[10px] uppercase tracking-wider text-slate-500 mb-2">Syntax</div>
								<ul className="space-y-2 text-xs">
									{docs.tokens.map((tok) => (
										<li key={tok.kind} className="font-mono">
											<div style={TOKEN_STYLE[tok.kind] ?? { color: C.ident }}>{tok.syntax}</div>
											<div className="text-slate-400 text-[11px] leading-snug">{tok.description}</div>
										</li>
									))}
								</ul>
							</section>
						</div>
					</>
				) : (
					<div className="p-3 text-xs text-slate-500 italic">Loading docs…</div>
				)}
			</div>
		</div>
	);
}

function Breadcrumb({ path }: { path: readonly PathSeg[] }) {
	return (
		<span className="text-[11px] font-mono text-slate-400 truncate">
			{path.map((seg, i) => (
				<span key={i}>
					{i > 0 && <span className="text-slate-600 mx-0.5">›</span>}
					<span className={typeof seg === "number" ? "text-slate-500" : "text-indigo-300"}>
						{String(seg)}
					</span>
				</span>
			))}
		</span>
	);
}

function ValidationBadge({ state }: { state: ValidationState }) {
	const color =
		state.kind === "ok" ? "text-emerald-400" :
		state.kind === "error" ? "text-red-400" :
		state.kind === "pending" ? "text-sky-400" : "text-slate-600";
	const label =
		state.kind === "ok" ? "valid" :
		state.kind === "error" ? "invalid" :
		state.kind === "pending" ? "checking" : "";
	if (!label) return null;
	return <span className={`text-[10px] uppercase tracking-wider ${color}`}>{label}</span>;
}
