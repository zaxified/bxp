import { useEffect, useState, useCallback, useRef, createContext, useContext } from "react";
import { ExprInline } from "../expr/highlight";
import { useTraceStore, type PathSeg } from "../store";
import type { FieldDoc } from "../../shared/types";

const HoverCtx = createContext<{
	key: string | null;
	enter: (k: string) => void;
	leave: () => void;
}>({ key: null, enter: () => {}, leave: () => {} });

type Kind = "object" | "array" | "string" | "number" | "boolean" | "null";
type NewType = "string" | "number" | "boolean" | "object" | "array";

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

function defaultForType(t: NewType): unknown {
	switch (t) {
		case "string":
			return "";
		case "number":
			return 0;
		case "boolean":
			return false;
		case "object":
			return {};
		case "array":
			return [];
	}
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

// Match a concrete path against a schema key pattern that uses `*` as wildcard.
// e.g. path ["conversion_templates","xtb","data_dir"] matches "conversion_templates.*.data_dir"
function matchSchemaKey(pattern: string, path: readonly PathSeg[]): boolean {
	const segs = pattern.split(".");
	if (segs.length !== path.length) return false;
	return segs.every((seg, i) => seg === "*" || seg === String(path[i]));
}

function findSchemaDoc(schema: FieldDoc[], path: readonly PathSeg[]): FieldDoc | null {
	return schema.find((f) => matchSchemaKey(f.key, path)) ?? null;
}

export function ConfigTree({ value }: { value: unknown }) {
	const [hoveredKey, setHoveredKey] = useState<string | null>(null);
	const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

	const enter = useCallback((k: string) => {
		if (timer.current) clearTimeout(timer.current);
		timer.current = setTimeout(() => { setHoveredKey(k); timer.current = null; }, 0);
	}, []);

	const leave = useCallback(() => {
		if (timer.current) { clearTimeout(timer.current); timer.current = null; }
		setHoveredKey(null);
	}, []);

	return (
		<HoverCtx.Provider value={{ key: hoveredKey, enter, leave }}>
			<div
				className="font-mono text-xs p-3"
				onMouseLeave={leave}
			>
				<TreeNode
					label="config"
					value={value}
					depth={0}
					path={[]}
					siblingCount={0}
					indexInParent={0}
					rootOpen
				/>
			</div>
		</HoverCtx.Provider>
	);
}

function TreeNode({
	label,
	value,
	depth,
	path,
	siblingCount,
	indexInParent,
	rootOpen = false,
}: {
	label: string | number;
	value: unknown;
	depth: number;
	path: readonly PathSeg[];
	siblingCount: number;
	indexInParent: number;
	rootOpen?: boolean;
}) {
	const [open, setOpen] = useState(rootOpen || depth < 2);
	const toggle = useCallback(() => setOpen((o) => !o), []);
	const k = kindOf(value);
	const composite = k === "object" || k === "array";

	const { key: hoveredKey, enter, leave } = useContext(HoverCtx);
	const pathKey = path.join("\0");
	const hovered = hoveredKey === pathKey;
	const hoverProps = {
		onMouseEnter: () => enter(pathKey),
		onMouseLeave: leave,
	};

	if (!composite) {
		const isExpr = k === "string" && isExprPath(path);
		return (
			<div className="flex items-baseline gap-2 py-0.5 hover:bg-slate-800/40 rounded" {...hoverProps}>
				<span className="w-4 shrink-0" />
				<LabelSpan label={label} path={path} />
				<span className="text-slate-600">:</span>
				{isExpr ? (
					<ExprLeaf text={String(value)} path={path} />
				) : (
					<EditableLeaf kind={k} value={value} path={path} />
				)}
				<RowActions
					path={path}
					siblingCount={siblingCount}
					indexInParent={indexInParent}
					visible={hovered}
				/>
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
				{...hoverProps}
			>
				<span className="w-4 shrink-0 text-slate-500 text-center select-none">
					{open ? "▾" : "▸"}
				</span>
				<LabelSpan label={label} path={path} />
				<span className="text-slate-600">:</span>
				<span className="text-slate-500">{summary(value)}</span>
				<AddChildControl parentPath={path} parentKind={k} />
				<RowActions
					path={path}
					siblingCount={siblingCount}
					indexInParent={indexInParent}
					visible={hovered}
				/>
			</div>
			{open && (
				<div style={{ paddingLeft: 16 }} className="border-l border-slate-800/80 ml-2">
					{entries.length === 0 ? (
						<div className="text-slate-600 italic py-0.5 pl-4">
							{k === "array" ? "(empty array)" : "(empty object)"}
						</div>
					) : (
						entries.map(([key, v], i) => (
							<TreeNode
								key={String(key)}
								label={key as string | number}
								value={v}
								depth={depth + 1}
								path={[...path, key as PathSeg]}
								siblingCount={entries.length}
								indexInParent={i}
							/>
						))
					)}
				</div>
			)}
		</div>
	);
}

function LabelSpan({ label, path }: { label: string | number; path: readonly PathSeg[] }) {
	const docs = useTraceStore((s) => s.docs);
	const [tooltipPos, setTooltipPos] = useState<{ x: number; y: number } | null>(null);

	const doc = docs && typeof label === "string" && path.length > 0
		? findSchemaDoc(docs.config_schema, path)
		: null;

	if (typeof label === "number") {
		return <span className="text-slate-500">[{label}]</span>;
	}

	return (
		<>
			<span
				className={`text-indigo-300 ${doc ? "underline decoration-dotted decoration-slate-500 cursor-help" : ""}`}
				onMouseEnter={(e) => {
					if (doc) {
						const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
						setTooltipPos({ x: rect.left, y: rect.bottom + 16 });
					}
				}}
				onMouseLeave={() => setTooltipPos(null)}
			>
				{label}
			</span>
			{tooltipPos && doc && (
				<span
					className="fixed z-50 min-w-64 max-w-80 bg-slate-900 border border-slate-600 rounded p-2 shadow-xl text-[11px] font-sans not-italic pointer-events-none"
					style={{ left: tooltipPos.x, top: tooltipPos.y }}
				>
					<div className="flex flex-wrap items-center gap-2 mb-1">
						<span className="text-sky-400 font-mono">{doc.type_name}</span>
						{doc.required && <span className="text-amber-400 text-[10px] uppercase tracking-wider">required</span>}
						{doc.default !== null && (
							<span className="text-slate-500 text-[10px]">default: <span className="text-emerald-400 font-mono">{doc.default}</span></span>
						)}
					</div>
					<div className="text-slate-300 leading-snug">{doc.description}</div>
				</span>
			)}
		</>
	);
}

// Structural-edit buttons for a non-root tree node. Shows on hover via the
// parent row's `group` class. Parent kind is inferred from the last path
// segment: numeric = array parent, string = object parent.
function RowActions({
	path,
	siblingCount,
	indexInParent,
	visible,
}: {
	path: readonly PathSeg[];
	siblingCount: number;
	indexInParent: number;
	visible: boolean;
}) {
	const deleteChild = useTraceStore((s) => s.deleteChild);
	const moveChild = useTraceStore((s) => s.moveChild);
	const duplicateChild = useTraceStore((s) => s.duplicateChild);

	if (path.length === 0) return null;
	const myKey = path[path.length - 1];
	const parentPath = path.slice(0, -1);
	const inArray = typeof myKey === "number";

	const handle = (fn: () => void) => (e: React.MouseEvent) => {
		e.stopPropagation();
		fn();
	};

	return (
		<span className={`ml-auto flex items-center gap-0.5 transition-opacity ${visible ? "opacity-100" : "opacity-0"}`}>
			{inArray && (
				<>
					<ActionButton
						title="Move up"
						disabled={indexInParent === 0}
						onClick={handle(() =>
							moveChild(parentPath, indexInParent, indexInParent - 1),
						)}
					>
						↑
					</ActionButton>
					<ActionButton
						title="Move down"
						disabled={indexInParent >= siblingCount - 1}
						onClick={handle(() =>
							moveChild(parentPath, indexInParent, indexInParent + 1),
						)}
					>
						↓
					</ActionButton>
				</>
			)}
			<ActionButton
				title="Duplicate"
				onClick={handle(() => duplicateChild(parentPath, myKey))}
			>
				⧉
			</ActionButton>
			<ActionButton
				title="Delete"
				onClick={handle(() => {
					if (confirm(`Delete ${String(myKey)}?`)) deleteChild(parentPath, myKey);
				})}
				danger
			>
				×
			</ActionButton>
		</span>
	);
}

// Inline + button on a composite container's header row. Opens a modal to
// pick the new entry's key (object) and type.
function AddChildControl({
	parentPath,
	parentKind,
}: {
	parentPath: readonly PathSeg[];
	parentKind: "object" | "array";
}) {
	const [open, setOpen] = useState(false);
	return (
		<>
			<ActionButton
				title="Add child"
				onClick={(e) => {
					e.stopPropagation();
					setOpen(true);
				}}
			>
				+
			</ActionButton>
			{open && (
				<AddChildDialog
					parentPath={parentPath}
					parentKind={parentKind}
					onClose={() => setOpen(false)}
				/>
			)}
		</>
	);
}

function AddChildDialog({
	parentPath,
	parentKind,
	onClose,
}: {
	parentPath: readonly PathSeg[];
	parentKind: "object" | "array";
	onClose: () => void;
}) {
	const insertChild = useTraceStore((s) => s.insertChild);
	const [keyName, setKeyName] = useState("");
	const [type, setType] = useState<NewType>("string");
	const [error, setError] = useState<string | null>(null);

	const confirm = () => {
		if (parentKind === "object") {
			const k = keyName.trim();
			if (k.length === 0) {
				setError("Key name cannot be empty");
				return;
			}
			insertChild(parentPath, k, defaultForType(type));
		} else {
			// Array: append. The store clamps to [0, length], so passing a
			// large index means "at end".
			insertChild(parentPath, Number.MAX_SAFE_INTEGER, defaultForType(type));
		}
		onClose();
	};

	return (
		<div
			className="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
			onClick={onClose}
		>
			<div
				className="bg-slate-900 border border-slate-700 rounded-lg p-4 min-w-80 font-mono text-xs"
				onClick={(e) => e.stopPropagation()}
			>
				<div className="text-slate-300 text-sm mb-3">
					Add entry to {parentKind}
				</div>
				{parentKind === "object" && (
					<div className="mb-3">
						<div className="text-slate-500 mb-1">Key</div>
						<input
							autoFocus
							value={keyName}
							onChange={(e) => {
								setKeyName(e.target.value);
								setError(null);
							}}
							onKeyDown={(e) => {
								if (e.key === "Enter") confirm();
								if (e.key === "Escape") onClose();
							}}
							placeholder="new_key"
							className="w-full bg-slate-950 text-indigo-300 border border-slate-700 rounded px-2 py-1"
						/>
					</div>
				)}
				<div className="mb-3">
					<div className="text-slate-500 mb-1">Type</div>
					<div className="flex flex-wrap gap-1">
						{(["string", "number", "boolean", "object", "array"] as NewType[]).map(
							(t) => (
								<button
									key={t}
									type="button"
									onClick={() => setType(t)}
									className={`px-2 py-1 border text-xs ${
										type === t
											? "border-sky-500 bg-sky-900/40 text-sky-200"
											: "border-slate-700 text-slate-400 hover:text-slate-100"
									}`}
								>
									{t}
								</button>
							),
						)}
					</div>
				</div>
				{error && <div className="text-red-400 mb-2">{error}</div>}
				<div className="flex justify-end gap-2 mt-4">
					<button
						type="button"
						onClick={onClose}
						className="px-3 py-1 text-slate-400 hover:text-slate-100"
					>
						Cancel
					</button>
					<button
						type="button"
						onClick={confirm}
						className="px-3 py-1 bg-sky-700 hover:bg-sky-600 text-white"
					>
						Add
					</button>
				</div>
			</div>
		</div>
	);
}

function ActionButton({
	title,
	onClick,
	disabled = false,
	danger = false,
	children,
}: {
	title: string;
	onClick: (e: React.MouseEvent) => void;
	disabled?: boolean;
	danger?: boolean;
	children: React.ReactNode;
}) {
	return (
		<button
			type="button"
			title={title}
			onClick={onClick}
			disabled={disabled}
			className={`text-xs w-5 h-5 leading-none flex items-center justify-center rounded ${
				disabled
					? "text-slate-700 cursor-not-allowed"
					: danger
						? "text-red-400 hover:bg-red-950/50"
						: "text-slate-400 hover:text-slate-100 hover:bg-slate-800"
			}`}
		>
			{children}
		</button>
	);
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

// Expression leaf: click selects it into the right panel editor.
function ExprLeaf({
	text,
	path,
}: {
	text: string;
	path: readonly PathSeg[];
}) {
	const setSelectedExpr = useTraceStore((s) => s.setSelectedExpr);
	const selectedExprPath = useTraceStore((s) => s.selectedExprPath);
	const active =
		selectedExprPath !== null &&
		selectedExprPath.length === path.length &&
		selectedExprPath.every((seg, i) => seg === path[i]);

	return (
		<span
			className={`flex-1 min-w-0 cursor-pointer inline-block px-0.5 ${
				active ? "bg-slate-700/60 outline outline-1 outline-slate-500" : ""
			}`}
			title="click to edit in panel"
			onClick={() => setSelectedExpr(path, text)}
		>
			<span className="text-slate-600">"</span>
			<ExprInline text={text} />
			<span className="text-slate-600">"</span>
		</span>
	);
}
