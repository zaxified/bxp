import { useEffect, useMemo, useState } from "react";
import { useTraceStore } from "../store";
import type { RowModel } from "../trace/model";

type RowStatus = "written" | "filtered" | "no-match" | "error";

function rowStatus(row: RowModel): RowStatus {
	if (row.hasError) return "error";
	if (row.outputs.length > 0) return "written";
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
	written: "▶",
	filtered: "▼",
	"no-match": "·",
	error: "✕",
};

const STATUS_TITLE: Record<RowStatus, string> = {
	written: "written to output",
	filtered: "filtered out",
	"no-match": "no matching rule",
	error: "error",
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

	const [filters, setFilters] = useState<Record<string, string>>({});

	const headers = file?.headers ?? [];

	const filteredRows = useMemo(() => {
		return rowList.filter((row) =>
			headers.every((h, i) => {
				const f = filters[h];
				if (!f) return true;
				return (row.fields[i] ?? "").toLowerCase().includes(f.toLowerCase());
			}),
		);
	}, [rowList, filters, headers]);

	// Auto-select the first row when a file is first populated.
	useEffect(() => {
		if (selectedFileId === null) return;
		if (selectedRowId !== null) return;
		if (rowList.length === 0) return;
		selectRow(rowList[0].id);
	}, [selectedFileId, selectedRowId, rowList, selectRow]);

	function setFilter(col: string, value: string) {
		setFilters((prev) => ({ ...prev, [col]: value }));
	}

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
		<div className="h-full" style={{ overflow: "scroll", scrollbarWidth: "thin" }}>
			<table className="text-xs font-mono border-collapse whitespace-nowrap">
				<thead className="sticky top-0 z-10 bg-slate-900">
					<tr>
						<th className="py-1 px-1 border-b border-r border-slate-800 w-8"></th>
						<th className="py-1 px-1 border-b border-r border-slate-800 w-8"></th>
						{headers.map((h) => (
							<th key={h} className="py-1 px-1 border-b border-r border-slate-800 last:border-r-0">
								<input
									type="text"
									value={filters[h] ?? ""}
									onChange={(e) => setFilter(h, e.target.value)}
									placeholder="filter"
									className="w-full bg-slate-800 text-slate-300 placeholder-slate-600 text-[11px] px-1.5 py-0.5 rounded border border-slate-700 focus:outline-none focus:border-slate-500"
								/>
							</th>
						))}
					</tr>
					<tr>
						<th className="py-1 px-2 text-left text-slate-500 font-normal border-b border-r border-slate-800 w-8">#</th>
						<th className="py-1 px-2 text-left text-slate-500 font-normal border-b border-r border-slate-800 w-8"></th>
						{headers.map((h) => (
							<th
								key={h}
								className="py-1 px-2 text-left text-slate-400 font-semibold border-b border-r border-slate-800 last:border-r-0"
							>
								{h}
							</th>
						))}
					</tr>
				</thead>
				<tbody>
					{filteredRows.map((row) => {
						const st = rowStatus(row);
						const active = row.id === selectedRowId;
						return (
							<tr
								key={row.id}
								onClick={() => selectRow(row.id)}
								className={`cursor-pointer border-b border-slate-800 ${
									active
										? "bg-slate-800"
										: "hover:bg-slate-800/50"
								}`}
							>
								<td className="py-1 px-2 text-slate-500 text-right border-r border-slate-800">
									{row.fileRow}
								</td>
								<td className={`py-1 px-2 text-center border-r border-slate-800 ${STATUS_STYLE[st]}`}>
									<span title={STATUS_TITLE[st]}>{STATUS_LABEL[st]}</span>
								</td>
								{headers.map((h, i) => (
									<td
										key={h}
										className="py-1 px-2 text-slate-300 border-r border-slate-800 last:border-r-0"
									>
										{row.fields[i] ?? ""}
									</td>
								))}
							</tr>
						);
					})}
				</tbody>
			</table>
		</div>
	);
}
