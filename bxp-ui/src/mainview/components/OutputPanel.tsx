import { useMemo } from "react";
import { useTraceStore } from "../store";

type ColDef = { header: string; variable: string };

function getOutputCols(configParsed: unknown, templateId: string): ColDef[] | null {
	if (!configParsed || typeof configParsed !== "object") return null;
	const templates = (configParsed as Record<string, unknown>).conversion_templates;
	if (!templates || typeof templates !== "object") return null;
	const tpl = (templates as Record<string, unknown>)[templateId];
	if (!tpl || typeof tpl !== "object") return null;
	const schema = (tpl as Record<string, unknown>).output_schema;
	if (!schema || typeof schema !== "object") return null;
	return Object.entries(schema as Record<string, string>).map(([header, variable]) => ({ header, variable }));
}

export function OutputPanel() {
	useTraceStore((s) => s.modelVersion);
	const file = useTraceStore((s) =>
		s.selectedFileId ? s.model.files[s.selectedFileId] : null,
	);
	const row = useTraceStore((s) =>
		s.selectedRowId ? s.model.rows[s.selectedRowId] : null,
	);
	const draftConfig = useTraceStore((s) => s.draftConfig);
	const configParsed = useTraceStore((s) => s.configParsed);

	const outputs = row?.outputs ?? [];

	const cols = useMemo((): ColDef[] => {
		if (file) {
			const fromConfig =
				getOutputCols(draftConfig, file.template) ??
				getOutputCols(configParsed, file.template);
			if (fromConfig) return fromConfig;
		}
		const colCount = outputs[0]?.length ?? 0;
		return Array.from({ length: colCount }, (_, i) => ({ header: `[${i + 1}]`, variable: "" }));
	}, [configParsed, draftConfig, file, outputs]);

	if (!row) {
		return (
			<div className="p-3 text-xs text-slate-500 italic">
				Select a row above.
			</div>
		);
	}

	if (outputs.length === 0) {
		return (
			<div className="p-3 text-xs text-slate-500 italic">
				No output (row not written).
			</div>
		);
	}

	return (
		<div className="h-full" style={{ overflow: "scroll", scrollbarWidth: "thin" }}>
			<table className="text-xs font-mono border-collapse whitespace-nowrap">
				<thead className="sticky top-0 z-10 bg-slate-900">
					<tr>
						<th className="py-1 px-2 text-left text-slate-500 font-normal border-b border-r border-slate-800 w-8">#</th>
						{cols.map((c) => (
							<th
								key={c.header}
								className="py-1 px-2 text-left font-normal border-b border-r border-slate-800 last:border-r-0"
							>
								<span className="text-slate-300 font-semibold">{c.header}</span>
								{c.variable && (
									<span className="text-indigo-400 ml-1 font-normal">({c.variable})</span>
								)}
							</th>
						))}
					</tr>
				</thead>
				<tbody>
					{outputs.map((values, idx) => (
						<tr
							key={idx}
							className="border-b border-slate-800 last:border-b-0"
						>
							<td className="py-1 px-2 text-slate-500 text-right border-r border-slate-800">
								{idx + 1}
							</td>
							{values.map((v, i) => (
								<td
									key={i}
									className="py-1 px-2 text-emerald-300 border-r border-slate-800 last:border-r-0"
								>
									{v}
								</td>
							))}
						</tr>
					))}
				</tbody>
			</table>
		</div>
	);
}
