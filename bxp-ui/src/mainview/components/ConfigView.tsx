import { useEffect } from "react";
import { useTraceStore } from "../store";
import { ConfigTree } from "./ConfigTree";
import { ExprPanel } from "./ExprPanel";

export function ConfigView() {
	const status = useTraceStore((s) => s.configStatus);
	const draft = useTraceStore((s) => s.draftConfig);
	const original = useTraceStore((s) => s.originalConfig);
	const configPath = useTraceStore((s) => s.configPath);
	const setConfigPath = useTraceStore((s) => s.setConfigPath);
	const openFileDialog = useTraceStore((s) => s.openFileDialog);
	const loadConfig = useTraceStore((s) => s.loadConfig);
	const saveDraft = useTraceStore((s) => s.saveDraft);
	const saveStatus = useTraceStore((s) => s.configSaveStatus);
	const historyLen = useTraceStore((s) => s.draftHistory.length);
	const futureLen = useTraceStore((s) => s.draftFuture.length);
	const undo = useTraceStore((s) => s.undo);
	const redo = useTraceStore((s) => s.redo);
	const resetDraft = useTraceStore((s) => s.resetDraft);

	const isDirty = draft !== original;

	useEffect(() => {
		if (status === "idle") loadConfig();
	}, [status, loadConfig]);

	useEffect(() => {
		if (status === "loaded" || status === "error") {
			loadConfig();
		}
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [configPath]);

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
				<ToolbarButton
					onClick={async () => {
						const path = await openFileDialog();
						if (path) {
							setConfigPath(path);
							loadConfig();
						}
					}}
					title="Open config file"
				>
					Open
				</ToolbarButton>
				<ToolbarButton onClick={() => loadConfig()} title="Reload from disk">
					Reload
				</ToolbarButton>
				<ToolbarButton
					onClick={() => resetDraft()}
					disabled={!isDirty}
					title="Discard all changes"
				>
					Reset
				</ToolbarButton>
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
					onClick={() => saveDraft()}
					disabled={!isDirty || saveStatus === "saving"}
					title="Save config to disk (atomic write via tmp + rename)"
				>
					{saveStatus === "saving" ? "Saving…" : "Save"}
				</ToolbarButton>
				{isDirty && (
					<span className="text-[10px] uppercase tracking-wider text-amber-400 px-2">
						● modified
					</span>
				)}
				<div className="flex-1" />
			</div>
			<div className="flex-1 min-h-0 flex overflow-hidden">
				{/* Left column — tree (always visible) */}
				<div className="w-[25%] shrink-0 border-r border-slate-800 overflow-y-auto">
					{status === "loading" && (
						<div className="p-4 text-xs text-slate-500 italic">Loading…</div>
					)}
					{status !== "loading" && draft !== null && (
						<ConfigTree value={draft} />
					)}
					{status !== "loading" && draft === null && (
						<div className="p-4 text-xs text-slate-500 italic">
							Config not parsed.
						</div>
					)}
				</div>
				{/* Right panel — Expr editor + function catalog */}
				<div className="flex-1 min-w-0 overflow-hidden">
					<ExprPanel />
				</div>
			</div>
		</div>
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
			className={`text-[10px] uppercase tracking-wider px-2 py-1 ${
				disabled
					? "text-slate-600 cursor-not-allowed"
					: "text-slate-400 hover:text-slate-100 hover:bg-slate-800"
			}`}
		>
			{children}
		</button>
	);
}
