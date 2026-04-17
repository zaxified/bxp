import { useState, useCallback } from "react";
import { ExprInline } from "../expr/highlight";
import { ExprEditor } from "./ExprEditor";

type Kind = "object" | "array" | "string" | "number" | "boolean" | "null";

type PathSeg = string | number;

function kindOf(v: unknown): Kind {
	if (v === null) return "null";
	if (Array.isArray(v)) return "array";
	const t = typeof v;
	if (t === "object") return "object";
	if (t === "string") return "string";
	if (t === "number") return "number";
	if (t === "boolean") return "boolean";
	return "null";
}

function summary(v: unknown): string {
	const k = kindOf(v);
	if (k === "object") {
		const n = Object.keys(v as object).length;
		return `{${n}}`;
	}
	if (k === "array") {
		return `[${(v as unknown[]).length}]`;
	}
	return "";
}

// Path-based classifier for expression string leaves. Mirrors the shape of
// conversion_templates[*] as documented in bxp-cli/CLAUDE.md. String leaves
// at these paths are rendered with bxp-expr highlighting and click-to-expand.
function isExprPath(path: readonly PathSeg[]): boolean {
	if (path.length < 4) return false;
	if (path[0] !== "conversion_templates") return false;
	// path[1] is template id
	const section = path[2];
	if (section === "input_schema") {
		// conversion_templates.<tpl>.input_schema.<$var>
		return path.length === 4;
	}
	if (section === "output_schema") {
		// conversion_templates.<tpl>.output_schema[<i>]
		return path.length === 4 && typeof path[3] === "number";
	}
	if (section === "row_rules") {
		// conversion_templates.<tpl>.row_rules[<i>].when
		// conversion_templates.<tpl>.row_rules[<i>].rows[<j>].<$var>
		if (path.length === 5 && path[4] === "when") return true;
		if (
			path.length === 7 &&
			path[4] === "rows" &&
			typeof path[5] === "number"
		) {
			return true;
		}
		return false;
	}
	if (section === "pre_pass") {
		// pre_pass.when | pre_pass.key | pre_pass.values.<k>
		if (path.length === 4 && (path[3] === "when" || path[3] === "key")) {
			return true;
		}
		if (path.length === 5 && path[3] === "values") return true;
		return false;
	}
	return false;
}

export function ConfigTree({ value }: { value: unknown }) {
	return (
		<div className="font-mono text-xs p-3">
			<TreeNode label="config" value={value} depth={0} path={[]} rootOpen />
		</div>
	);
}

function TreeNode({
	label,
	value,
	depth,
	path,
	rootOpen = false,
}: {
	label: string | number;
	value: unknown;
	depth: number;
	path: readonly PathSeg[];
	rootOpen?: boolean;
}) {
	const [open, setOpen] = useState(rootOpen || depth < 2);
	const toggle = useCallback(() => setOpen((o) => !o), []);
	const k = kindOf(value);
	const composite = k === "object" || k === "array";

	if (!composite) {
		const isExpr = k === "string" && isExprPath(path);
		return (
			<div className="flex items-baseline gap-2 py-0.5">
				<span className="w-4 shrink-0" />
				<LabelSpan label={label} />
				<span className="text-slate-600">:</span>
				{isExpr ? (
					<ExprLeaf text={String(value)} />
				) : (
					<Leaf kind={k} value={value} />
				)}
			</div>
		);
	}

	const entries =
		k === "array"
			? (value as unknown[]).map((v, i) => [i, v] as const)
			: Object.entries(value as object);

	return (
		<div>
			<div
				className="flex items-baseline gap-2 py-0.5 cursor-pointer hover:bg-slate-800/40 rounded"
				onClick={toggle}
			>
				<span className="w-4 shrink-0 text-slate-500 text-center select-none">
					{open ? "▾" : "▸"}
				</span>
				<LabelSpan label={label} />
				<span className="text-slate-600">:</span>
				<span className="text-slate-500">{summary(value)}</span>
			</div>
			{open && (
				<div style={{ paddingLeft: 16 }} className="border-l border-slate-800/80 ml-2">
					{entries.length === 0 ? (
						<div className="text-slate-600 italic py-0.5 pl-4">
							{k === "array" ? "(empty array)" : "(empty object)"}
						</div>
					) : (
						entries.map(([key, v]) => (
							<TreeNode
								key={String(key)}
								label={key as string | number}
								value={v}
								depth={depth + 1}
								path={[...path, key as PathSeg]}
							/>
						))
					)}
				</div>
			)}
		</div>
	);
}

function LabelSpan({ label }: { label: string | number }) {
	if (typeof label === "number") {
		return <span className="text-slate-500">[{label}]</span>;
	}
	return <span className="text-indigo-300">{label}</span>;
}

function Leaf({ kind, value }: { kind: Kind; value: unknown }) {
	if (kind === "string") {
		return (
			<span className="text-emerald-300 whitespace-pre-wrap break-all">
				"{String(value)}"
			</span>
		);
	}
	if (kind === "number") {
		return <span className="text-amber-300">{String(value)}</span>;
	}
	if (kind === "boolean") {
		return <span className="text-sky-300">{String(value)}</span>;
	}
	return <span className="text-slate-500 italic">null</span>;
}

// Expression leaf: default is a lightweight syntax-highlighted span (no editor
// instance). Clicking toggles a full CM6 editor. Read-only for now — tree edits
// are a later Phase 6 task.
function ExprLeaf({ text }: { text: string }) {
	const [expanded, setExpanded] = useState(false);
	return (
		<span className="flex-1 min-w-0">
			<span
				className="cursor-pointer inline-block"
				title={expanded ? "click to collapse" : "click to expand editor"}
				onClick={() => setExpanded((e) => !e)}
			>
				<span className="text-slate-600">"</span>
				<ExprInline text={text} />
				<span className="text-slate-600">"</span>
			</span>
			{expanded && (
				<div className="mt-1 mb-2">
					<ExprEditor value={text} readOnly height={text.length > 60 ? 80 : 48} />
				</div>
			)}
		</span>
	);
}
