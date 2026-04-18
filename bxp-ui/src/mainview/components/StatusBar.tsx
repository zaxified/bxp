import { useTraceStore } from "../store";

export function StatusBar() {
	const status = useTraceStore((s) => s.status);
	const runError = useTraceStore((s) => s.runError);
	const stderr = useTraceStore((s) => s.stderr);
	const rawLines = useTraceStore((s) => s.rawLines);
	const done = useTraceStore((s) => s.model.done);
	const issues = useTraceStore((s) => s.model.issues);
	const files = useTraceStore((s) => s.model.files);
	const fileOrder = useTraceStore((s) => s.model.fileOrder);
	const configPath = useTraceStore((s) => s.configPath);
	const openInEditor = useTraceStore((s) => s.openInEditor);
	const configStatus = useTraceStore((s) => s.configStatus);
	const configError = useTraceStore((s) => s.configError);
	const validationError = useTraceStore((s) => s.configValidationError);
	const saveError = useTraceStore((s) => s.configSaveError);

	const totals = aggregateStats(files, fileOrder);

	const statusColor =
		status === "running"
			? "text-amber-300"
			: status === "error"
				? "text-red-400"
				: done
					? done.exitCode === 0
						? "text-emerald-400"
						: done.exitCode === 2
							? "text-amber-400"
							: "text-red-400"
					: "text-slate-500";

	const configStatusColor =
		configStatus === "loaded"
			? "text-emerald-400"
			: configStatus === "loading"
				? "text-sky-400"
				: configStatus === "error"
					? "text-red-400"
					: "text-slate-500";

	const hasConfigError = configError || validationError || saveError;

	return (
		<footer className="border-t border-slate-800 bg-slate-900 text-xs text-slate-400 shrink-0">
			<div className="px-4 py-0 h-9 flex items-center gap-4">
				<span className={`${configStatusColor} text-[10px] uppercase tracking-wider leading-none`}>
					{configStatus}
				</span>
				{configPath && (
					<span className="inline-flex items-center gap-1 shrink-0 max-w-[40%]">
						<button
							type="button"
							title="Open in system editor"
							onClick={() => openInEditor(configPath)}
							className="p-0 leading-none text-slate-500 hover:text-slate-200 transition-colors inline-flex items-center"
						>
							<IconEdit />
						</button>
						<span className="truncate leading-none">{configPath}</span>
					</span>
				)}
				<span className={`${statusColor} leading-none`}>
					{status}{done && ` · exit ${done.exitCode}`}
				</span>
				<span className="leading-none text-slate-500">
					trace lines: <span className="text-slate-400">{rawLines}</span>
				</span>
				<span className="leading-none text-slate-500">
					input rows: <span className="text-slate-400">{totals.rows}</span>
				</span>
				<span className="leading-none text-slate-500">
					output rows: <span className="text-slate-400">{totals.written}</span>
					{totals.errors > 0 && (
						<span className="text-red-400"> · errors: {totals.errors}</span>
					)}
					{totals.warnings > 0 && (
						<span className="text-amber-400"> · warnings: {totals.warnings}</span>
					)}
				</span>
				{issues.length > 0 && (
					<span className="text-red-400 leading-none">parse issues: {issues.length}</span>
				)}
				{runError && (
					<span className="text-red-400 truncate leading-none">rpc: {runError}</span>
				)}
				<div className="ml-auto flex items-center gap-2 shrink-0">
					{stderr.length > 0 && (
						<details className="flex items-center">
							<summary className="text-red-400 cursor-pointer leading-none">
								stderr ({stderr.length}B)
							</summary>
							<pre className="absolute right-4 bottom-10 bg-slate-950 border border-red-900/40 p-3 text-xs text-red-300 whitespace-pre-wrap max-w-[80ch] max-h-[40vh] overflow-auto shadow-xl z-10">
								{stderr}
							</pre>
						</details>
					)}
				</div>
			</div>
			{hasConfigError && (
				<div className="px-4 pb-1.5 flex flex-col gap-0.5">
					{validationError && (
						<span className="text-amber-400 truncate">bxp-fmt: {validationError}</span>
					)}
					{configError && (
						<span className="text-red-400 truncate">{configError}</span>
					)}
					{saveError && (
						<span className="text-red-400 truncate">save: {saveError}</span>
					)}
				</div>
			)}
		</footer>
	);
}

function IconEdit() {
	return (
		<svg
			xmlns="http://www.w3.org/2000/svg"
			width="12"
			height="12"
			viewBox="0 0 24 24"
			fill="none"
			stroke="currentColor"
			strokeWidth="2"
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
			<path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" />
		</svg>
	);
}

function aggregateStats(
	files: Record<string, { stats: { rows: number; written: number; errors: number; warnings: number } | null; rowIds: string[] }>,
	fileOrder: string[],
) {
	let rows = 0;
	let written = 0;
	let errors = 0;
	let warnings = 0;
	for (const id of fileOrder) {
		const f = files[id];
		if (!f) continue;
		if (f.stats) {
			rows += f.stats.rows;
			written += f.stats.written;
			errors += f.stats.errors;
			warnings += f.stats.warnings;
		} else {
			rows += f.rowIds.length;
		}
	}
	return { rows, written, errors, warnings };
}
