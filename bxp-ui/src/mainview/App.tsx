import { useState, useEffect, useRef } from "react";
import { FileList } from "./components/FileList";
import { RowList } from "./components/RowList";
import { RowDetail } from "./components/RowDetail";
import { SectionHeader } from "./components/RowDetail";
import { OutputPanel } from "./components/OutputPanel";
import { StatusBar } from "./components/StatusBar";
import { ConfigView } from "./components/ConfigView";
import { useTraceStore } from "./store";

type Tab = "config" | "debug";

const GITHUB_URL = "https://github.com/zaxified/bxp";

function App() {
	const [tab, setTab] = useState<Tab>("config");
	const theme = useTraceStore((s) => s.theme);
	const toggleTheme = useTraceStore((s) => s.toggleTheme);
	const openUrl = useTraceStore((s) => s.openUrl);

	useEffect(() => {
		const STEP = 0.1;
		const MIN = 0.5;
		const MAX = 3.0;
		const getZoom = () => parseFloat((document.documentElement.style as CSSStyleDeclaration & { zoom?: string }).zoom || "1");
		const setZoom = (z: number) => {
			const clamped = Math.max(MIN, Math.min(MAX, Math.round(z * 10) / 10));
			(document.documentElement.style as CSSStyleDeclaration & { zoom?: string }).zoom = String(clamped);
		};
		const onKey = (e: KeyboardEvent) => {
			if (!e.ctrlKey) return;
			if (e.key === "=" || e.key === "+") { e.preventDefault(); setZoom(getZoom() + STEP); }
			else if (e.key === "-") { e.preventDefault(); setZoom(getZoom() - STEP); }
			else if (e.key === "0") { e.preventDefault(); setZoom(1.0); }
		};
		window.addEventListener("keydown", onKey);
		return () => window.removeEventListener("keydown", onKey);
	}, []);

	return (
		<div className="h-screen overflow-hidden flex flex-col bg-slate-950 text-slate-100">
			<nav className="flex items-center gap-1 px-3 py-1 border-b border-slate-800 bg-slate-900/60">
				<TopTab active={tab === "config"} onClick={() => setTab("config")}>
					CONFIG
				</TopTab>
				<TopTab active={tab === "debug"} onClick={() => setTab("debug")}>
					DEBUG
				</TopTab>
				<div className="ml-auto flex items-center gap-1">
					<TopTab active={false} onClick={() => { void openUrl(GITHUB_URL); }}>
						GITHUB
					</TopTab>
					<TopTab active={false} onClick={toggleTheme}>
						{theme === "slate" ? "BLUE" : "GRAY"}
					</TopTab>
				</div>
			</nav>
			<main className="flex-1 min-h-0">
				{tab === "debug" && <DebugPanes />}
				{tab === "config" && <ConfigView />}
			</main>
			<StatusBar />
		</div>
	);
}

function DebugPanes() {
	// label (28px) + filter row (26px) + header (26px) + 5 data rows (26px each) = ~210px
	const ROW_PANEL_H = "210px";
	// header (24px) + 4 data rows (28px each) = ~136px
	const OUTPUT_PANEL_H = "176px";
	const templateId = useTraceStore((s) => s.templateId);
	const setTemplateId = useTraceStore((s) => s.setTemplateId);
	const draft = useTraceStore((s) => s.draftConfig);
	const status = useTraceStore((s) => s.status);
	const runDryRun = useTraceStore((s) => s.runDryRun);
	const running = status === "running";

	const templateNames: string[] = (() => {
		if (draft == null || typeof draft !== "object") return [];
		const ct = (draft as Record<string, unknown>).conversion_templates;
		if (ct == null || typeof ct !== "object" || Array.isArray(ct)) return [];
		return Object.keys(ct as object);
	})();

	return (
		<div className="h-full flex flex-col">
			<div className="flex items-center gap-2 px-3 py-1.5 border-b border-slate-800 bg-slate-900/40 shrink-0">
				<button
					type="button"
					onClick={() => { void runDryRun(); }}
					disabled={running}
					className={`text-xs py-0.5 border font-medium w-20 text-center ${
						running
							? "border-slate-700 bg-slate-700 text-slate-400 cursor-not-allowed"
							: "border-emerald-700 bg-emerald-700/30 text-emerald-300 hover:bg-emerald-700/60"
					}`}
				>
					{running ? "running…" : "dry-run"}
				</button>
				<TemplateSelect
					value={templateId}
					options={templateNames}
					onChange={setTemplateId}
				/>
			</div>
			<div className="flex-1 min-h-0 flex">
				<aside className="flex-none w-64 flex flex-col border-r border-slate-800 bg-slate-900/40">
					<FilesHeader />
					<div className="flex-1 min-h-0" style={{ overflow: "auto", scrollbarWidth: "thin" }}>
						<FileList />
					</div>
				</aside>
				<div className="flex-1 min-w-0 flex flex-col">
					<div
						className="flex-none flex flex-col border-b border-slate-800 bg-slate-900/20"
						style={{ height: ROW_PANEL_H }}
					>
						<RowsInHeader />
						<div className="flex-1 min-h-0">
							<RowList />
						</div>
					</div>
					<section className="flex-1 min-h-0 overflow-hidden">
						<RowDetail />
					</section>
					<div
						className="flex-none flex flex-col border-t border-slate-800 bg-slate-900/20"
						style={{ height: OUTPUT_PANEL_H }}
					>
						<RowsOutHeader />
						<div className="flex-1 min-h-0">
							<OutputPanel />
						</div>
					</div>
				</div>
			</div>
		</div>
	);
}

function TopTab({
	active,
	onClick,
	children,
}: {
	active: boolean;
	onClick: () => void;
	children: React.ReactNode;
}) {
	return (
		<button
			type="button"
			onClick={onClick}
			className={`text-xs px-3 py-1.5 ${
				active
					? "bg-slate-800 text-slate-100"
					: "text-slate-400 hover:text-slate-100 hover:bg-slate-800/60"
			}`}
		>
			{children}
		</button>
	);
}

function FilesHeader() {
	const count = useTraceStore((s) => s.model.fileOrder.length);
	return <SectionHeader title="Files" subtitle={count > 0 ? `(${count})` : undefined} />;
}

function RowsInHeader() {
	const count = useTraceStore((s) =>
		s.selectedFileId ? (s.model.files[s.selectedFileId]?.rowIds.length ?? 0) : 0,
	);
	return <SectionHeader title="Rows in" subtitle={count > 0 ? `(${count})` : undefined} />;
}

function RowsOutHeader() {
	const count = useTraceStore((s) =>
		s.selectedRowId ? (s.model.rows[s.selectedRowId]?.outputs.length ?? 0) : 0,
	);
	return <SectionHeader title="Rows out" subtitle={`(${count})`} />;
}

function TemplateSelect({
	value,
	options,
	onChange,
}: {
	value: string;
	options: string[];
	onChange: (v: string) => void;
}) {
	const [open, setOpen] = useState(false);
	const ref = useRef<HTMLDivElement>(null);
	const items = ["", ...options];
	const label = value === "" ? "all templates" : value;

	useEffect(() => {
		if (!open) return;
		const handler = (e: MouseEvent) => {
			if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
		};
		document.addEventListener("mousedown", handler);
		return () => document.removeEventListener("mousedown", handler);
	}, [open]);

	return (
		<div ref={ref} className="relative">
			<button
				type="button"
				onClick={() => setOpen((o) => !o)}
				className="flex items-center gap-1.5 bg-slate-800 border border-slate-700 px-2 py-0.5 text-xs text-slate-200 hover:border-slate-500 focus:outline-none focus:border-slate-500 whitespace-nowrap"
			>
				{label}
				<svg width="8" height="8" viewBox="0 0 8 8" className="text-slate-400 shrink-0">
					<path d="M1 2.5l3 3 3-3" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round"/>
				</svg>
			</button>
			{open && (
				<ul className="absolute left-0 top-full mt-0.5 z-50 bg-slate-800 border border-slate-700 shadow-xl py-0.5 min-w-full">
					{items.map((name) => (
						<li key={name}>
							<button
								type="button"
								onClick={() => { onChange(name); setOpen(false); }}
								className={`w-full text-left px-3 py-1 text-xs whitespace-nowrap hover:bg-slate-700 ${
									value === name ? "text-slate-100" : "text-slate-300"
								}`}
							>
								{name === "" ? "all templates" : name}
							</button>
						</li>
					))}
				</ul>
			)}
		</div>
	);
}

export default App;
