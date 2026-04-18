import { useTraceStore } from "../store";

export function FileList() {
	useTraceStore((s) => s.modelVersion); // force re-render on flush
	const fileOrder = useTraceStore((s) => s.model.fileOrder);
	const files = useTraceStore((s) => s.model.files);
	const selectedFileId = useTraceStore((s) => s.selectedFileId);
	const selectFile = useTraceStore((s) => s.selectFile);

	if (fileOrder.length === 0) {
		return (
			<div className="p-3 text-xs text-slate-500 italic">
				No files yet. Click Run Dry-Run.
			</div>
		);
	}

	return (
		<ul className="text-xs min-w-max">
			{fileOrder.map((id) => {
				const f = files[id];
				if (!f) return null;
				const name = basename(f.path);
				const rows = f.rowIds.length;
				const written = f.stats?.written ?? null;
				const errors = f.stats?.errors ?? 0;
				const active = id === selectedFileId;
				return (
					<li key={id}>
						<button
							type="button"
							onClick={() => selectFile(id)}
							className={`w-full text-left px-3 py-2 border-b border-slate-800 ${
								active
									? "bg-slate-800 text-emerald-300"
									: "text-slate-300 hover:bg-slate-800/60"
							}`}
						>
							<div className="font-medium whitespace-nowrap">{name}</div>
							<div className="text-[10px] text-slate-500 mt-0.5 whitespace-nowrap">
								{f.template} · {rows} rows
								{written !== null && ` · ${written} written`}
								{errors > 0 && (
									<span className="text-red-400"> · {errors} err</span>
								)}
							</div>
						</button>
					</li>
				);
			})}
		</ul>
	);
}

function basename(path: string): string {
	const i = path.lastIndexOf("/");
	return i >= 0 ? path.slice(i + 1) : path;
}
