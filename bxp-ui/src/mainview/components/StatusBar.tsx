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

	return (
		<footer className="border-t border-slate-800 bg-slate-900 px-4 py-2 text-xs text-slate-400 flex gap-4 items-center">
			<span className={statusColor}>
				status: {status}
				{done && ` · exit ${done.exitCode}`}
			</span>
			<span>lines: {rawLines}</span>
			<span>
				rows: {totals.rows} · written: {totals.written}
				{totals.errors > 0 && (
					<span className="text-red-400"> · errors: {totals.errors}</span>
				)}
				{totals.warnings > 0 && (
					<span className="text-amber-400">
						{" "}
						· warnings: {totals.warnings}
					</span>
				)}
			</span>
			{issues.length > 0 && (
				<span className="text-red-400">parse issues: {issues.length}</span>
			)}
			{runError && (
				<span className="text-red-400 truncate">rpc: {runError}</span>
			)}
			{stderr.length > 0 && (
				<details className="ml-auto">
					<summary className="text-red-400 cursor-pointer">
						stderr ({stderr.length}B)
					</summary>
					<pre className="absolute right-4 bottom-10 bg-slate-950 border border-red-900/40 rounded p-3 text-xs text-red-300 whitespace-pre-wrap max-w-[80ch] max-h-[40vh] overflow-auto shadow-xl z-10">
						{stderr}
					</pre>
				</details>
			)}
		</footer>
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
