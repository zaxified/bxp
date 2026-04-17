import { useEffect, useState, useCallback } from "react";
import { ExprInline } from "../expr/highlight";
import { ExprEditor } from "./ExprEditor";
import { useTraceStore, type PathSeg } from "../store";

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

// Path-based classifier for expression string leaves. Mirrors the shape of
// conversion_templates[*] as documented in bxp-cli/CLAUDE.md. String leaves
// at these paths are rendered with bxp-expr highlighting and click-to-expand.
function isExprPath(path: readonly PathSeg[]): boolean {
	if (path.length < 4) return false;
	if (path[0] !== "conversion_templates") return false;
	const section = path[2];
	if (section === "input_schema") return path.length === 4;
	if (section === "output_schema") {
		return path.length === 4 && typeof path[3] === "number";
	}
	if (section === "row_rules") {
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
					<ExprLeaf text={String(value)} path={path} />
				) : (
					<EditableLeaf kind={k} value={value} path={path} />
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

function EditableLeaf({
	kind,
	value,
	path,
}: {
	kind: Kind;
	value: unknown;
	path: readonly PathSeg[];
}) {
	const editLeaf = useTraceStore((s) => s.editLeaf);
	if (kind === "string") {
		return (
			<EditableString
				value={String(value)}
				onCommit={(v) => editLeaf(path, v)}
			/>
		);
	}
	if (kind === "number") {
		return (
			<EditableNumber
				value={Number(value)}
				onCommit={(v) => editLeaf(path, v)}
			/>
		);
	}
	if (kind === "boolean") {
		return (
			<EditableBoolean
				value={Boolean(value)}
				onCommit={(v) => editLeaf(path, v)}
			/>
		);
	}
	return <span className="text-slate-500 italic">null</span>;
}

function EditableString({
	value,
	onCommit,
}: {
	value: string;
	onCommit: (v: string) => void;
}) {
	const [editing, setEditing] = useState(false);
	const [draft, setDraft] = useState(value);
	useEffect(() => {
		if (!editing) setDraft(value);
	}, [value, editing]);

	if (!editing) {
		return (
			<span
				className="text-emerald-300 whitespace-pre-wrap break-all cursor-text hover:bg-slate-800/40 rounded px-0.5"
				onClick={() => setEditing(true)}
				title="click to edit"
			>
				"{value}"
			</span>
		);
	}

	const commit = () => {
		setEditing(false);
		if (draft !== value) onCommit(draft);
	};
	const cancel = () => {
		setDraft(value);
		setEditing(false);
	};

	return (
		<input
			autoFocus
			value={draft}
			onChange={(e) => setDraft(e.target.value)}
			onBlur={commit}
			onKeyDown={(e) => {
				if (e.key === "Enter") commit();
				if (e.key === "Escape") cancel();
			}}
			className="bg-slate-900 text-emerald-300 border border-slate-700 rounded px-1 font-mono text-xs min-w-40"
		/>
	);
}

function EditableNumber({
	value,
	onCommit,
}: {
	value: number;
	onCommit: (v: number) => void;
}) {
	const [editing, setEditing] = useState(false);
	const [draft, setDraft] = useState(String(value));
	useEffect(() => {
		if (!editing) setDraft(String(value));
	}, [value, editing]);

	if (!editing) {
		return (
			<span
				className="text-amber-300 cursor-text hover:bg-slate-800/40 rounded px-0.5"
				onClick={() => setEditing(true)}
				title="click to edit"
			>
				{value}
			</span>
		);
	}

	const commit = () => {
		setEditing(false);
		const n = Number(draft);
		if (!Number.isNaN(n) && n !== value) onCommit(n);
	};
	const cancel = () => {
		setDraft(String(value));
		setEditing(false);
	};

	return (
		<input
			autoFocus
			type="number"
			value={draft}
			onChange={(e) => setDraft(e.target.value)}
			onBlur={commit}
			onKeyDown={(e) => {
				if (e.key === "Enter") commit();
				if (e.key === "Escape") cancel();
			}}
			className="bg-slate-900 text-amber-300 border border-slate-700 rounded px-1 font-mono text-xs w-24"
		/>
	);
}

function EditableBoolean({
	value,
	onCommit,
}: {
	value: boolean;
	onCommit: (v: boolean) => void;
}) {
	return (
		<button
			type="button"
			onClick={() => onCommit(!value)}
			className="text-sky-300 cursor-pointer hover:bg-slate-800/40 rounded px-0.5"
			title="click to toggle"
		>
			{String(value)}
		</button>
	);
}

// Expression leaf: click-to-expand CM6 editor. Editable; commits on blur so a
// whole edit session is a single undo step.
function ExprLeaf({
	text,
	path,
}: {
	text: string;
	path: readonly PathSeg[];
}) {
	const [expanded, setExpanded] = useState(false);
	const [draft, setDraft] = useState(text);
	const editLeaf = useTraceStore((s) => s.editLeaf);
	useEffect(() => {
		setDraft(text);
	}, [text]);

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
					<ExprEditor
						value={draft}
						onChange={setDraft}
						onBlur={(v) => {
							if (v !== text) editLeaf(path, v);
						}}
						height={text.length > 60 ? 80 : 48}
					/>
				</div>
			)}
		</span>
	);
}
