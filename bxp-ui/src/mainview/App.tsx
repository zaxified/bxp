import { useState, useEffect } from "react";
import { TopBar } from "./components/TopBar";
import { FileList } from "./components/FileList";
import { RowList } from "./components/RowList";
import { RowDetail } from "./components/RowDetail";
import { SectionHeader } from "./components/RowDetail";
import { OutputPanel } from "./components/OutputPanel";
import { StatusBar } from "./components/StatusBar";
import { ConfigView } from "./components/ConfigView";
import { ExprPlayground } from "./components/ExprPlayground";
import { useTraceStore } from "./store";

type Tab = "config" | "debug" | "expr";

function App() {
	const [tab, setTab] = useState<Tab>("debug");

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
			<TopBar />
			<nav className="flex items-center gap-1 px-3 py-1 border-b border-slate-800 bg-slate-900/60">
				<TopTab active={tab === "config"} onClick={() => setTab("config")}>
					Config
				</TopTab>
				<TopTab active={tab === "debug"} onClick={() => setTab("debug")}>
					Debug
				</TopTab>
				<TopTab active={tab === "expr"} onClick={() => setTab("expr")}>
					Expr
				</TopTab>
			</nav>
			<main className="flex-1 min-h-0">
				{tab === "debug" && <DebugPanes />}
				{tab === "config" && <ConfigView />}
				{tab === "expr" && <ExprPlayground />}
			</main>
			<StatusBar />
		</div>
	);
}

function DebugPanes() {
	// label (28px) + filter row (26px) + header (26px) + 5 data rows (26px each) = ~210px
	const ROW_PANEL_H = "210px";
	// header (24px) + 4 data rows (28px each) = ~136px
	const OUTPUT_PANEL_H = "136px";
	return (
		<div className="h-full flex">
			<aside className="flex-none w-64 flex flex-col border-r border-slate-800 bg-slate-900/40">
				<FilesHeader />
				<div className="flex-1 min-h-0 overflow-y-auto">
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
			className={`text-xs px-3 py-1.5 rounded ${
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

export default App;
