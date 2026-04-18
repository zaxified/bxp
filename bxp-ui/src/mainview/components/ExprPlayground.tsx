import { useEffect, useState, useMemo } from "react";
import { useTraceStore } from "../store";
import { ExprEditor } from "./ExprEditor";
import { bxpExpr } from "../expr/language";

const EXAMPLES: readonly { label: string; expr: string }[] = [
	{ label: "date convert", expr: "DATE_CONVERT([Date], '%Y-%m-%d', '%d.%m.%Y')" },
	{ label: "buy/sell", expr: "IF([Qty] > 0, 'BUY', 'SELL')" },
	{ label: "ticker map", expr: "TICKER([Symbol])" },
	{ label: "price parts", expr: "PRICE_VALUE([Price]) & ' ' & PRICE_CURRENCY([Price])" },
	{ label: "coalesce", expr: "COALESCE([ISIN], LOOKUP([Symbol], 'isin'), '')" },
];

type ValidationState =
	| { kind: "idle" }
	| { kind: "pending" }
	| { kind: "ok" }
	| { kind: "error"; message: string };

export function ExprPlayground() {
	const [expr, setExpr] = useState(EXAMPLES[0].expr);
	const [state, setState] = useState<ValidationState>({ kind: "idle" });
	const validateExpr = useTraceStore((s) => s.validateExpr);
	const docs = useTraceStore((s) => s.docs);
	const languageExt = useMemo(
		() => (docs ? bxpExpr(docs.functions, docs.keywords) : null),
		[docs],
	);

	// Debounced validation: 300ms after last keystroke.
	useEffect(() => {
		if (expr.trim().length === 0) {
			setState({ kind: "idle" });
			return;
		}
		setState({ kind: "pending" });
		const h = setTimeout(async () => {
			const res = await validateExpr(expr);
			if (res.ok) {
				setState({ kind: "ok" });
			} else {
				setState({ kind: "error", message: res.error ?? "unknown error" });
			}
		}, 300);
		return () => clearTimeout(h);
	}, [expr, validateExpr]);

	const marker = state.kind === "error" ? state.message : null;

	return (
		<div className="h-full flex gap-4 p-4 overflow-hidden">
			<div className="flex-1 min-w-0 flex flex-col gap-3">
				<div className="flex items-center gap-2">
					<h2 className="text-xs font-semibold uppercase tracking-wider text-slate-400">
						Expression
					</h2>
					<StatusBadge state={state} />
					<div className="flex-1" />
					<div className="flex items-center gap-1">
						{EXAMPLES.map((ex) => (
							<button
								key={ex.label}
								type="button"
								onClick={() => setExpr(ex.expr)}
								className="text-[10px] uppercase tracking-wider text-slate-500 hover:text-slate-100 px-2 py-1 hover:bg-slate-800"
							>
								{ex.label}
							</button>
						))}
					</div>
				</div>

				<ExprEditor value={expr} onChange={setExpr} height={160} marker={marker} languageExt={languageExt} />

				<div className="text-xs">
					{state.kind === "error" && (
						<pre className="text-red-400 whitespace-pre-wrap break-all p-2 border border-red-900/40 bg-red-950/20 rounded font-mono">
							{state.message}
						</pre>
					)}
					{state.kind === "ok" && (
						<div className="text-emerald-400 font-mono">
							bxp-fmt: OK
						</div>
					)}
					{state.kind === "pending" && (
						<div className="text-slate-500 italic">validating…</div>
					)}
					{state.kind === "idle" && (
						<div className="text-slate-500 italic">
							Type an expression to validate.
						</div>
					)}
				</div>
			</div>

			<aside className="w-80 shrink-0 overflow-y-auto border-l border-slate-800 pl-4">
				<h2 className="text-xs font-semibold uppercase tracking-wider text-slate-400 mb-2">
					Functions
				</h2>
				<ul className="space-y-2 text-xs">
					{(docs?.functions ?? []).map((f) => (
						<li key={f.name} className="font-mono">
							<div className="text-indigo-300">{f.signature}</div>
							<div className="text-slate-400 text-[11px] leading-snug">
								{f.description}
							</div>
						</li>
					))}
				</ul>
			</aside>
		</div>
	);
}

function StatusBadge({ state }: { state: ValidationState }) {
	const color =
		state.kind === "ok"
			? "text-emerald-400"
			: state.kind === "error"
				? "text-red-400"
				: state.kind === "pending"
					? "text-sky-400"
					: "text-slate-500";
	const label =
		state.kind === "ok"
			? "valid"
			: state.kind === "error"
				? "invalid"
				: state.kind === "pending"
					? "checking"
					: "idle";
	return (
		<span className={`text-[10px] uppercase tracking-wider ${color}`}>
			{label}
		</span>
	);
}
