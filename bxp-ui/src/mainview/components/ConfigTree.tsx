import { useState, useCallback } from "react";

type Kind = "object" | "array" | "string" | "number" | "boolean" | "null";

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

export function ConfigTree({ value }: { value: unknown }) {
	return (
		<div className="font-mono text-xs p-3">
			<TreeNode label="config" value={value} depth={0} rootOpen />
		</div>
	);
}

function TreeNode({
	label,
	value,
	depth,
	rootOpen = false,
}: {
	label: string | number;
	value: unknown;
	depth: number;
	rootOpen?: boolean;
}) {
	// Auto-expand top two levels; user can collapse.
	const [open, setOpen] = useState(rootOpen || depth < 2);
	const toggle = useCallback(() => setOpen((o) => !o), []);
	const k = kindOf(value);
	const composite = k === "object" || k === "array";

	if (!composite) {
		return (
			<div className="flex items-baseline gap-2 py-0.5">
				<span className="w-4 shrink-0" />
				<LabelSpan label={label} />
				<span className="text-slate-600">:</span>
				<Leaf kind={k} value={value} />
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
				<span className="text-slate-600">
					{k === "array" ? ":" : ":"}
				</span>
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
