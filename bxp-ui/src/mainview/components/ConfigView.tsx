import { useEffect, useState } from "react";
import { useTraceStore } from "../store";
import { ConfigTree } from "./ConfigTree";
import { ConfigRaw } from "./ConfigRaw";

type Sub = "tree" | "raw";

export function ConfigView() {
	const status = useTraceStore((s) => s.configStatus);
	const text = useTraceStore((s) => s.configText);
	const parsed = useTraceStore((s) => s.configParsed);
	const error = useTraceStore((s) => s.configError);
	const validationError = useTraceStore((s) => s.configValidationError);
	const configPath = useTraceStore((s) => s.configPath);
	const loadConfig = useTraceStore((s) => s.loadConfig);

	const [sub, setSub] = useState<Sub>("tree");

	// Auto-load when the user switches to Config tab and nothing is loaded yet
	// (or when the path changes).
	useEffect(() => {
		if (status === "idle") loadConfig();
	}, [status, loadConfig]);

	useEffect(() => {
		// Trigger reload when configPath changes after an initial load.
		if (status === "loaded" || status === "error") {
			loadConfig();
		}
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [configPath]);

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
				<button
					type="button"
					onClick={() => loadConfig()}
					className="text-[10px] uppercase tracking-wider text-slate-400 hover:text-slate-100 px-2 py-1 rounded hover:bg-slate-800"
				>
					Reload
				</button>
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

			<div className="flex-1 min-h-0 overflow-auto">
				{status === "loading" && (
					<div className="p-4 text-xs text-slate-500 italic">Loading…</div>
				)}
				{status !== "loading" && sub === "tree" && parsed !== null && (
					<ConfigTree value={parsed} />
				)}
				{status !== "loading" && sub === "tree" && parsed === null && (
					<div className="p-4 text-xs text-slate-500 italic">
						Config not parsed.
					</div>
				)}
				{status !== "loading" && sub === "raw" && <ConfigRaw text={text} />}
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
