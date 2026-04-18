import { useTraceStore } from "../store";

export function TopBar() {
	const theme = useTraceStore((s) => s.theme);
	const toggleTheme = useTraceStore((s) => s.toggleTheme);

	return (
		<header className="border-b border-slate-800 bg-slate-900 px-4 py-2 flex gap-3 items-center justify-end">
			<button
				type="button"
				onClick={toggleTheme}
				title={`Theme: ${theme} (click to switch)`}
				className="text-[10px] uppercase tracking-wider px-3 py-1.5 border border-slate-700 bg-slate-800 text-slate-300 hover:bg-slate-700 hover:text-slate-100"
			>
				{theme === "slate" ? "Blue" : "Gray"}
			</button>
		</header>
	);
}
