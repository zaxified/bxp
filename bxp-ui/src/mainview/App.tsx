import { useState, useSyncExternalStore } from "react";
import { traceBus } from "./traceBus";

function useTrace() {
	return useSyncExternalStore(
		(l) => traceBus.subscribe(l),
		() => `${traceBus.lines.length}:${traceBus.stderr.length}`,
	);
}

function App() {
	useTrace();
	const [configPath, setConfigPath] = useState(
		"/home/zak/workspace/zig/bxp/DEV/bxp-cli.json",
	);
	const [templateId, setTemplateId] = useState("xtb2_cash");
	const [running, setRunning] = useState(false);
	const [exitCode, setExitCode] = useState<number | null>(null);
	const [error, setError] = useState<string | null>(null);

	async function handleRun() {
		setRunning(true);
		setExitCode(null);
		setError(null);
		try {
			const res = await traceBus.runDryRun(configPath, templateId);
			setExitCode(res.exitCode);
		} catch (e) {
			setError(e instanceof Error ? e.message : String(e));
		} finally {
			setRunning(false);
		}
	}

	const ndjsonText = traceBus.lines.join("\n");

	return (
		<div className="min-h-screen bg-slate-950 text-slate-100 font-mono">
			<div className="container mx-auto px-6 py-6 max-w-6xl">
				<h1 className="text-2xl font-bold mb-4">bxp-ui — dry-run debugger</h1>

				<div className="grid grid-cols-[1fr_auto_auto] gap-3 mb-4 items-end">
					<label className="flex flex-col text-xs">
						<span className="text-slate-400 mb-1">Config path</span>
						<input
							type="text"
							value={configPath}
							onChange={(e) => setConfigPath(e.target.value)}
							className="bg-slate-800 border border-slate-700 rounded px-3 py-2 text-sm"
							disabled={running}
						/>
					</label>
					<label className="flex flex-col text-xs">
						<span className="text-slate-400 mb-1">Template (optional)</span>
						<input
							type="text"
							value={templateId}
							onChange={(e) => setTemplateId(e.target.value)}
							className="bg-slate-800 border border-slate-700 rounded px-3 py-2 text-sm w-48"
							disabled={running}
							placeholder="all"
						/>
					</label>
					<button
						type="button"
						onClick={handleRun}
						disabled={running}
						className="bg-emerald-600 hover:bg-emerald-500 disabled:bg-slate-700 disabled:text-slate-400 text-white font-medium rounded px-5 py-2 text-sm"
					>
						{running ? "Running…" : "Run Dry-Run"}
					</button>
				</div>

				<div className="flex gap-3 mb-2 text-xs text-slate-400">
					<span>lines: {traceBus.lines.length}</span>
					{exitCode !== null && (
						<span
							className={exitCode === 0 ? "text-emerald-400" : "text-red-400"}
						>
							exit: {exitCode}
						</span>
					)}
					{error && <span className="text-red-400">error: {error}</span>}
				</div>

				<textarea
					className="w-full h-[60vh] bg-slate-900 border border-slate-800 rounded p-3 text-xs text-slate-200 resize-none"
					readOnly
					value={ndjsonText}
				/>

				{traceBus.stderr.length > 0 && (
					<details className="mt-3">
						<summary className="text-xs text-red-400 cursor-pointer">
							stderr ({traceBus.stderr.length} bytes)
						</summary>
						<pre className="bg-slate-900 border border-red-900/40 rounded p-3 text-xs text-red-300 mt-2 whitespace-pre-wrap">
							{traceBus.stderr}
						</pre>
					</details>
				)}
			</div>
		</div>
	);
}

export default App;
