import { useState } from "react";
import { TopBar } from "./components/TopBar";
import { FileList } from "./components/FileList";
import { RowList } from "./components/RowList";
import { RowDetail } from "./components/RowDetail";
import { StatusBar } from "./components/StatusBar";
import { ConfigView } from "./components/ConfigView";

type Tab = "config" | "debug";

function App() {
	const [tab, setTab] = useState<Tab>("debug");

	return (
		<div className="h-screen flex flex-col bg-slate-950 text-slate-100">
			<TopBar />
			<nav className="flex items-center gap-1 px-3 py-1 border-b border-slate-800 bg-slate-900/60">
				<TopTab active={tab === "config"} onClick={() => setTab("config")}>
					Config
				</TopTab>
				<TopTab active={tab === "debug"} onClick={() => setTab("debug")}>
					Debug
				</TopTab>
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
	return (
		<div className="h-full grid grid-cols-[16rem_20rem_1fr]">
			<aside className="overflow-y-auto border-r border-slate-800 bg-slate-900/40">
				<div className="px-3 py-2 text-[10px] uppercase tracking-wider text-slate-500 border-b border-slate-800">
					Files
				</div>
				<FileList />
			</aside>
			<aside className="overflow-y-auto border-r border-slate-800 bg-slate-900/20">
				<div className="px-3 py-2 text-[10px] uppercase tracking-wider text-slate-500 border-b border-slate-800">
					Rows
				</div>
				<RowList />
			</aside>
			<section className="overflow-hidden">
				<RowDetail />
			</section>
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

export default App;
