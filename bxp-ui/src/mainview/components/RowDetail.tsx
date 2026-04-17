import { useTraceStore } from "../store";
import type { VarEntry } from "../trace/model";

export function RowDetail() {
	useTraceStore((s) => s.modelVersion); // force re-render on flush
	const file = useTraceStore((s) =>
		s.selectedFileId ? s.model.files[s.selectedFileId] : null,
	);
	const row = useTraceStore((s) =>
		s.selectedRowId ? s.model.rows[s.selectedRowId] : null,
	);
	const outputHeaders = useOutputHeaders();

	if (!row || !file) {
		return (
			<div className="p-6 text-sm text-slate-500 italic">
				Select a row to inspect.
			</div>
		);
	}

	return (
		<div className="p-4 space-y-6 overflow-y-auto h-full">
			<Section title={`Row ${row.fileRow}`} subtitle={file.template}>
				<FieldsTable headers={file.headers} values={row.fields} />
			</Section>

			<Section title="Variables" subtitle={`${row.vars.length} entries`}>
				<VariablesTable vars={row.vars} />
			</Section>

			<Section
				title="Rules"
				subtitle={
					row.matchedRuleIndex !== null
						? `matched rule [${row.matchedRuleIndex}]`
						: "no rule matched"
				}
			>
				<RulesTable
					rules={row.rules}
					matchedIndex={row.matchedRuleIndex}
					filtered={row.filteredReason}
				/>
			</Section>

			<Section title="Output" subtitle={row.output ? "row_output" : "—"}>
				<OutputTable headers={outputHeaders} values={row.output} />
			</Section>
		</div>
	);
}

function useOutputHeaders(): string[] {
	// output_schema ordering isn't in the trace stream — we fall back to the
	// count of values and label them pos 1..N. Phase 4 will parse the config
	// and surface the real headers.
	useTraceStore((s) => s.modelVersion);
	const row = useTraceStore((s) =>
		s.selectedRowId ? s.model.rows[s.selectedRowId] : null,
	);
	if (!row?.output) return [];
	return row.output.map((_, i) => `[${i + 1}]`);
}

function Section({
	title,
	subtitle,
	children,
}: {
	title: string;
	subtitle?: string;
	children: React.ReactNode;
}) {
	return (
		<section>
			<h3 className="text-xs font-semibold uppercase tracking-wider text-slate-400 mb-2">
				{title}
				{subtitle && (
					<span className="text-slate-600 normal-case ml-2 font-normal">
						{subtitle}
					</span>
				)}
			</h3>
			{children}
		</section>
	);
}

function FieldsTable({
	headers,
	values,
}: {
	headers: string[];
	values: string[];
}) {
	return (
		<table className="w-full text-xs font-mono border border-slate-800">
			<tbody>
				{headers.map((h, i) => (
					<tr key={h} className="border-b border-slate-800 last:border-b-0">
						<td className="py-1 px-2 text-slate-500 w-40">{h}</td>
						<td className="py-1 px-2 text-slate-200">{values[i] ?? ""}</td>
					</tr>
				))}
			</tbody>
		</table>
	);
}

function VariablesTable({ vars }: { vars: VarEntry[] }) {
	if (vars.length === 0) {
		return <div className="text-xs text-slate-500 italic">No vars.</div>;
	}
	return (
		<table className="w-full text-xs font-mono border border-slate-800">
			<thead>
				<tr className="text-slate-500 text-left">
					<th className="py-1 px-2 w-32 font-normal">name</th>
					<th className="py-1 px-2 font-normal">expr</th>
					<th className="py-1 px-2 w-64 font-normal">value</th>
				</tr>
			</thead>
			<tbody>
				{vars.map((v, i) => {
					const isError = v.kind === "error";
					return (
						<tr
							key={`${v.name}-${i}`}
							className="border-t border-slate-800"
						>
							<td className="py-1 px-2 text-indigo-300">{v.name}</td>
							<td className="py-1 px-2 text-slate-300 whitespace-pre-wrap break-all">
								{v.expr || <span className="text-slate-600">—</span>}
							</td>
							<td
								className={`py-1 px-2 whitespace-pre-wrap break-all ${
									isError ? "text-red-400" : "text-emerald-300"
								}`}
							>
								{isError
									? `${v.error}${v.detail ? ` ${v.detail}` : ""}`
									: v.value || <span className="text-slate-600">""</span>}
							</td>
						</tr>
					);
				})}
			</tbody>
		</table>
	);
}

function RulesTable({
	rules,
	matchedIndex,
	filtered,
}: {
	rules: { ruleIndex: number; when: string; matched: boolean }[];
	matchedIndex: number | null;
	filtered: string | null;
}) {
	if (rules.length === 0 && !filtered) {
		return <div className="text-xs text-slate-500 italic">No rules evaluated.</div>;
	}
	return (
		<>
			{filtered && (
				<div className="text-xs text-amber-400 mb-2">
					Row filtered: {filtered}
				</div>
			)}
			<table className="w-full text-xs font-mono border border-slate-800">
				<tbody>
					{rules.map((r) => (
						<tr
							key={r.ruleIndex}
							className={`border-b border-slate-800 last:border-b-0 ${
								r.ruleIndex === matchedIndex ? "bg-emerald-950/30" : ""
							}`}
						>
							<td className="py-1 px-2 text-slate-500 w-10 text-right">
								{r.ruleIndex}
							</td>
							<td className="py-1 px-2 w-10">
								<span
									className={r.matched ? "text-emerald-400" : "text-slate-600"}
								>
									{r.matched ? "✓" : "·"}
								</span>
							</td>
							<td className="py-1 px-2 text-slate-300 whitespace-pre-wrap break-all">
								{r.when}
							</td>
						</tr>
					))}
				</tbody>
			</table>
		</>
	);
}

function OutputTable({
	headers,
	values,
}: {
	headers: string[];
	values: string[] | null;
}) {
	if (!values) {
		return (
			<div className="text-xs text-slate-500 italic">
				No output (row not written).
			</div>
		);
	}
	return (
		<table className="w-full text-xs font-mono border border-slate-800">
			<tbody>
				{values.map((v, i) => (
					<tr
						key={`${i}-${headers[i] ?? ""}`}
						className="border-b border-slate-800 last:border-b-0"
					>
						<td className="py-1 px-2 text-slate-500 w-20">{headers[i]}</td>
						<td className="py-1 px-2 text-slate-200 whitespace-pre-wrap break-all">
							{v}
						</td>
					</tr>
				))}
			</tbody>
		</table>
	);
}
