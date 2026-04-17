import { useEffect, useMemo, useState } from "react";
import JSON5 from "json5";
import { useTraceStore } from "../store";
import { ConfigTree } from "./ConfigTree";
import { ConfigRaw } from "./ConfigRaw";
import { buildRoundtrippedText } from "../config/roundtrip";

type Sub = "tree" | "raw";

export function ConfigView() {
	const status = useTraceStore((s) => s.configStatus);
	const text = useTraceStore((s) => s.configText);
	const draft = useTraceStore((s) => s.draftConfig);
	const original = useTraceStore((s) => s.originalConfig);
	const error = useTraceStore((s) => s.configError);
	const validationError = useTraceStore((s) => s.configValidationError);
	const configPath = useTraceStore((s) => s.configPath);
	const loadConfig = useTraceStore((s) => s.loadConfig);
	const saveDraft = useTraceStore((s) => s.saveDraft);
	const saveStatus = useTraceStore((s) => s.configSaveStatus);
	const saveError = useTraceStore((s) => s.configSaveError);
	const historyLen = useTraceStore((s) => s.draftHistory.length);
	const futureLen = useTraceStore((s) => s.draftFuture.length);
	const undo = useTraceStore((s) => s.undo);
	const redo = useTraceStore((s) => s.redo);
	const resetDraft = useTraceStore((s) => s.resetDraft);

	const [sub, setSub] = useState<Sub>("tree");

	const isDirty = draft !== original;

	// Serialize draft for the Raw view. Parses the original text into a CST
	// via @croct/json5-parser, patches only the leaves that actually changed,
	// and emits the result — so comments, whitespace, and key order of
	// untouched subtrees round-trip byte-for-byte.
	const draftText = useMemo(() => {
		if (draft == null) return text;
		return buildRoundtrippedText(text, original, draft, (v) =>
			JSON5.stringify(v, null, 2),
		);
	}, [draft, original, text]);

	// Auto-load when the user switches to Config tab and nothing is loaded yet
	// (or when the path changes).
	useEffect(() => {
		if (status === "idle") loadConfig();
	}, [status, loadConfig]);

	useEffect(() => {
		if (status === "loaded" || status === "error") {
			loadConfig();
		}
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [configPath]);

	// Keyboard shortcuts: Ctrl/Cmd+Z for undo, Ctrl/Cmd+Shift+Z or Ctrl+Y for redo.
	useEffect(() => {
		const onKey = (e: KeyboardEvent) => {
			const mod = e.ctrlKey || e.metaKey;
			if (!mod) return;
			if (e.key === "z" || e.key === "Z") {
				e.preventDefault();
				if (e.shiftKey) redo();
				else undo();
			} else if (e.key === "y" || e.key === "Y") {
				e.preventDefault();
				redo();
			}
		};
		window.addEventListener("keydown", onKey);
		return () => window.removeEventListener("keydown", onKey);
	}, [undo, redo]);

	return (
		<div className="h-full flex flex-col">
			<div className="flex items-center gap-1 px-3 py-1.5 border-b border-slate-800 bg-slate-900/40">
				<SubTab active={sub === "tree"} onClick={() => setSub("tree")}>
					Tree
				</SubTab>
				<SubTab active={sub === "raw"} onClick={() => setSub("raw")}>
					Raw JSON5
				</SubTab>
				<div className="flex-1" />
				{isDirty && (
					<span className="text-[10px] uppercase tracking-wider text-amber-400 px-2">
						● modified
					</span>
				)}
				<ToolbarButton
					onClick={() => undo()}
					disabled={historyLen === 0}
					title="Undo (Ctrl+Z)"
				>
					Undo
				</ToolbarButton>
				<ToolbarButton
					onClick={() => redo()}
					disabled={futureLen === 0}
					title="Redo (Ctrl+Shift+Z)"
				>
					Redo
				</ToolbarButton>
				<ToolbarButton
					onClick={() => resetDraft()}
					disabled={!isDirty}
					title="Discard all changes"
				>
					Reset
				</ToolbarButton>
				<ToolbarButton
					onClick={() => saveDraft()}
					disabled={!isDirty || saveStatus === "saving"}
					title="Save config to disk (atomic write via tmp + rename)"
				>
					{saveStatus === "saving" ? "Saving…" : "Save"}
				</ToolbarButton>
				<ToolbarButton onClick={() => loadConfig()} title="Reload from disk">
					Reload
				</ToolbarButton>
				<StatusBadge status={status} />
			</div>

			{validationError && (
				<div className="px-3 py-1.5 text-xs text-amber-400 border-b border-amber-900/40 bg-amber-950/20">
					bxp-fmt: {validationError}
				</div>
			)}
			{error && (
				<div className="px-3 py-1.5 text-xs text-red-400 border-b border-red-900/40 bg-red-950/20">
					{error}
				</div>
			)}
			{saveError && (
				<div className="px-3 py-1.5 text-xs text-red-400 border-b border-red-900/40 bg-red-950/20">
					save failed: {saveError}
				</div>
			)}
			<div className="flex-1 min-h-0 overflow-auto">
				{status === "loading" && (
					<div className="p-4 text-xs text-slate-500 italic">Loading…</div>
				)}
				{status !== "loading" && sub === "tree" && draft !== null && (
					<ConfigTree value={draft} />
				)}
				{status !== "loading" && sub === "tree" && draft === null && (
					<div className="p-4 text-xs text-slate-500 italic">
						Config not parsed.
					</div>
				)}
				{status !== "loading" && sub === "raw" && (
					<ConfigRaw text={isDirty ? draftText : text} />
				)}
			</div>
		</div>
	);
}

function SubTab({
	active,
	onClick,
	children,
}: {
	active: boolean;
	onClick: () => void;
	children: React.ReactNode;
}) {
	return (
		<button
			type="button"
			onClick={onClick}
			className={`text-xs px-3 py-1 rounded ${
				active
					? "bg-slate-800 text-slate-100"
					: "text-slate-400 hover:text-slate-100 hover:bg-slate-800/60"
			}`}
		>
			{children}
		</button>
	);
}

function ToolbarButton({
	onClick,
	disabled = false,
	title,
	children,
}: {
	onClick: () => void;
	disabled?: boolean;
	title?: string;
	children: React.ReactNode;
}) {
	return (
		<button
			type="button"
			onClick={onClick}
			disabled={disabled}
			title={title}
			className={`text-[10px] uppercase tracking-wider px-2 py-1 rounded ${
				disabled
					? "text-slate-600 cursor-not-allowed"
					: "text-slate-400 hover:text-slate-100 hover:bg-slate-800"
			}`}
		>
			{children}
		</button>
	);
}

function StatusBadge({ status }: { status: string }) {
	const color =
		status === "loaded"
			? "text-emerald-400"
			: status === "loading"
				? "text-sky-400"
				: status === "error"
					? "text-red-400"
					: "text-slate-500";
	return (
		<span className={`text-[10px] uppercase tracking-wider ${color} ml-2`}>
			{status}
		</span>
	);
}
