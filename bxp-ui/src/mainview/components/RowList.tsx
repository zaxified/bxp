import { useEffect, useMemo } from "react";
import { useTraceStore } from "../store";
import type { RowModel } from "../trace/model";

type RowStatus = "written" | "filtered" | "no-match" | "error";

function rowStatus(row: RowModel): RowStatus {
	if (row.hasError) return "error";
	if (row.output) return "written";
	if (row.filteredReason) return "filtered";
	return "no-match";
}

const STATUS_STYLE: Record<RowStatus, string> = {
	written: "text-emerald-400",
	filtered: "text-amber-400",
	"no-match": "text-slate-500",
	error: "text-red-400",
};

const STATUS_LABEL: Record<RowStatus, string> = {
	written: "out",
	filtered: "filt",
	"no-match": "skip",
	error: "err",
};

export function RowList() {
	const modelVersion = useTraceStore((s) => s.modelVersion);
	const selectedFileId = useTraceStore((s) => s.selectedFileId);
	const file = useTraceStore((s) =>
		s.selectedFileId ? s.model.files[s.selectedFileId] : null,
	);
	const rows = useTraceStore((s) => s.model.rows);
	const selectedRowId = useTraceStore((s) => s.selectedRowId);
	const selectRow = useTraceStore((s) => s.selectRow);

	const rowList = useMemo(
		() => (file ? file.rowIds.map((id) => rows[id]).filter(Boolean) : []),
		// modelVersion forces recompute after builder mutates rowIds in place.
		[file, rows, modelVersion],
	);

	// Auto-select the first row when a file is first populated.
	useEffect(() => {
		if (selectedFileId === null) return;
		if (selectedRowId !== null) return;
		if (rowList.length === 0) return;
		selectRow(rowList[0].id);
	}, [selectedFileId, selectedRowId, rowList, selectRow]);

	if (!file) {
		return (
			<div className="p-3 text-xs text-slate-500 italic">
				Select a file on the left.
			</div>
		);
	}

	if (rowList.length === 0) {
		return (
			<div className="p-3 text-xs text-slate-500 italic">
				No rows yet in this file.
			</div>
		);
	}

	return (
		<ul className="text-xs font-mono">
			{rowList.map((row) => {
				const st = rowStatus(row);
				const active = row.id === selectedRowId;
				return (
					<li key={row.id}>
						<button
							type="button"
							onClick={() => selectRow(row.id)}
							className={`w-full text-left px-3 py-1.5 border-b border-slate-800 flex gap-2 items-baseline ${
								active
									? "bg-slate-800 text-slate-100"
									: "text-slate-300 hover:bg-slate-800/60"
							}`}
						>
							<span className="text-slate-500 w-8 text-right">
								{row.fileRow}
							</span>
							<span className={`${STATUS_STYLE[st]} w-8 text-[10px]`}>
								{STATUS_LABEL[st]}
							</span>
							<span className="flex-1 truncate text-slate-400">
								{row.fields.slice(0, 3).join(" · ")}
							</span>
						</button>
					</li>
				);
			})}
		</ul>
	);
}
