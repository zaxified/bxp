import { useTraceStore } from "../store";

export function TopBar() {
	const configPath = useTraceStore((s) => s.configPath);
	const templateId = useTraceStore((s) => s.templateId);
	const status = useTraceStore((s) => s.status);
	const setConfigPath = useTraceStore((s) => s.setConfigPath);
	const setTemplateId = useTraceStore((s) => s.setTemplateId);
	const runDryRun = useTraceStore((s) => s.runDryRun);

	const running = status === "running";

	return (
		<header className="border-b border-slate-800 bg-slate-900 px-4 py-3 flex gap-3 items-end">
			<label className="flex flex-col text-xs flex-1 min-w-0">
				<span className="text-slate-400 mb-1">Config path</span>
				<input
					type="text"
					value={configPath}
					onChange={(e) => setConfigPath(e.target.value)}
					className="bg-slate-800 border border-slate-700 rounded px-3 py-2 text-sm"
					disabled={running}
				/>
			</label>
			<label className="flex flex-col text-xs w-56">
				<span className="text-slate-400 mb-1">Template (optional)</span>
				<input
					type="text"
					value={templateId}
					onChange={(e) => setTemplateId(e.target.value)}
					className="bg-slate-800 border border-slate-700 rounded px-3 py-2 text-sm"
					disabled={running}
					placeholder="all"
				/>
			</label>
			<button
				type="button"
				onClick={() => {
					void runDryRun();
				}}
				disabled={running}
				className="bg-emerald-600 hover:bg-emerald-500 disabled:bg-slate-700 disabled:text-slate-400 text-white font-medium rounded px-5 py-2 text-sm self-end"
			>
				{running ? "Running…" : "Run Dry-Run"}
			</button>
		</header>
	);
}
