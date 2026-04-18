import React from "react";
import { useTraceStore } from "../store";
import type { VarEntry } from "../trace/model";
import { ExprInline } from "../expr/highlight";

export function RowDetail() {
	useTraceStore((s) => s.modelVersion); // force re-render on flush
	const file = useTraceStore((s) =>
		s.selectedFileId ? s.model.files[s.selectedFileId] : null,
	);
	const row = useTraceStore((s) =>
		s.selectedRowId ? s.model.rows[s.selectedRowId] : null,
	);

	if (!row || !file) {
		return (
			<div className="p-6 text-sm text-slate-500 italic">
				Select a row to inspect.
			</div>
		);
	}

	const errorCount = row.vars.filter((v) => v.kind === "error").length;

	return (
		<div className="h-full overflow-y-auto">
			{errorCount > 0 && (
				<div className="flex items-center gap-2 text-xs text-red-300 bg-red-950/30 border-b border-red-900/50 px-4 py-2">
					<span className="text-red-400">⚠</span>
					<span>
						{errorCount} variable {errorCount === 1 ? "error" : "errors"} in
						this row — see Variables below.
					</span>
				</div>
			)}
			<div className="flex h-full">
				{/* Left column 18% — Row fields */}
				<div className="w-[18%] min-w-0 border-r border-slate-800 flex flex-col">
					<SectionHeader title="Row selected" />
					<div className="flex-1 min-h-0 overflow-y-auto overflow-x-hidden">
						<FieldsTable headers={file.headers} values={row.fields} />
					</div>
				</div>
				{/* Right column 82% — Variables + Rules */}
				<div className="flex-1 min-w-0 flex flex-col">
					<SectionHeader title="Row transform" />
					<div className="flex-1 min-h-0 overflow-y-auto">
					<div className="p-4 space-y-6">
						<Section
							title="Variables"
							subtitle={
								errorCount > 0
									? `${row.vars.length} entries · ${errorCount} error${errorCount === 1 ? "" : "s"}`
									: `${row.vars.length} entries`
							}
						>
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

						{row.matchedRuleIndex !== null && (() => {
							const matched = row.rules.find(r => r.ruleIndex === row.matchedRuleIndex);
							return (
								<Section title="Rule results" subtitle={`rule [${row.matchedRuleIndex}]`}>
									{matched && matched.rows.length > 0
										? <RuleResultsTable rows={matched.rows} />
										: <div className="text-xs text-slate-500 italic">No override rows.</div>
									}
								</Section>
							);
						})()}
					</div>
					</div>
				</div>
			</div>
		</div>
	);
}

export function SectionHeader({ title, subtitle }: { title: string; subtitle?: string }) {
	return (
		<div className="px-3 py-2 text-[10px] uppercase tracking-wider text-slate-500 border-b border-slate-800 sticky top-0 bg-slate-900">
			{title}
			{subtitle && (
				<span className="text-slate-600 normal-case ml-2 font-normal">{subtitle}</span>
			)}
		</div>
	);
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
		<table className="text-xs font-mono" style={{ width: "100%", tableLayout: "fixed" }}>
			<colgroup>
				<col style={{ width: "50%" }} />
				<col style={{ width: "50%" }} />
			</colgroup>
			<tbody>
				{headers.map((h, i) => (
					<tr key={h} className="border-b border-slate-800">
						<td className="py-1 px-3 text-slate-500" style={{ overflowWrap: "break-word", wordBreak: "break-word", whiteSpace: "normal" }}>{h}</td>
						<td className="py-1 px-3 text-slate-200" style={{ overflowWrap: "break-word", wordBreak: "break-word", whiteSpace: "normal" }}>{values[i] ?? ""}</td>
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
		<table className="w-full text-xs font-mono border border-slate-800 table-fixed">
			<colgroup>
				<col style={{ width: "10%" }} />
				<col className="w-6" />
				<col style={{ width: "10%" }} />
				<col />
			</colgroup>
			<thead>
				<tr className="text-slate-500 text-left">
					<th className="py-1 px-2 font-normal truncate">result</th>
					<th className="py-1 px-2 font-normal"></th>
					<th className="py-1 px-2 font-normal truncate">variable</th>
					<th className="py-1 px-2 font-normal">expr</th>
				</tr>
			</thead>
			<tbody>
				{vars.map((v, i) => {
					const isError = v.kind === "error";
					return (
						<tr
							key={`${v.name}-${i}`}
							className={`border-t border-slate-800 ${
								isError ? "bg-red-950/20" : ""
							}`}
						>
							<td className="py-1 px-2 align-top truncate">
								{isError ? (
									<div>
										<div className="text-red-400 font-semibold truncate">{v.error}</div>
										{v.detail && (
											<div className="text-red-300/80 text-[11px] mt-0.5 truncate">
												{v.detail}
											</div>
										)}
									</div>
								) : (
									<span className="text-emerald-300">
										{v.value || <span className="text-slate-600">""</span>}
									</span>
								)}
							</td>
							<td
								className={`py-1 px-2 text-center ${
									isError ? "text-red-400" : "text-slate-700"
								}`}
							>
								{isError ? "⚠" : ""}
							</td>
							<td className="py-1 px-2 text-indigo-300 align-top truncate">{v.name}</td>
							<td className="py-1 px-2 text-slate-300 align-top">
								{v.expr ? (
									<ExprInline text={v.expr} />
								) : (
									<span className="text-slate-600">—</span>
								)}
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
	rules: { ruleIndex: number; when: string; matched: boolean; rows: Record<string, string>[] }[];
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
							className={`border-b border-slate-800 ${
								r.ruleIndex === matchedIndex ? "bg-emerald-950/30" : ""
							}`}
						>
							<td className="py-1 px-2 text-slate-500 w-10 text-right">
								{r.ruleIndex}
							</td>
							<td className="py-1 px-2 w-10">
								<span className={r.matched ? "text-emerald-400" : "text-slate-600"}>
									{r.matched ? "✓" : "·"}
								</span>
							</td>
							<td className="py-1 px-2 text-slate-300">
								<ExprInline text={r.when} />
							</td>
						</tr>
					))}
				</tbody>
			</table>
		</>
	);
}

function RuleResultsTable({ rows }: { rows: Record<string, string>[] }) {
	const allKeys = Array.from(new Set(rows.flatMap(r => Object.keys(r))));
	return (
		<table className="w-full text-xs font-mono border border-slate-800">
			<thead>
				<tr className="text-slate-500 text-left border-b border-slate-800">
					<th className="py-1 px-2 font-normal w-6">#</th>
					{allKeys.map(k => (
						<th key={k} className="py-1 px-2 font-normal text-indigo-300">{k}</th>
					))}
				</tr>
			</thead>
			<tbody>
				{rows.map((override, i) => (
					<tr key={i} className="border-t border-slate-800">
						<td className="py-1 px-2 text-slate-600">{i + 1}</td>
						{allKeys.map(k => {
							const v = override[k];
							return (
								<td key={k} className="py-1 px-2 align-top">
									{v === undefined
										? <span className="text-slate-700">—</span>
										: v === ""
											? <span className="text-slate-600">""</span>
											: <ExprInline text={v} />
									}
								</td>
							);
						})}
					</tr>
				))}
			</tbody>
		</table>
	);
}
