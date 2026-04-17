export function ConfigRaw({ text }: { text: string }) {
	if (text.length === 0) {
		return (
			<div className="p-4 text-xs text-slate-500 italic">
				No config loaded.
			</div>
		);
	}
	return (
		<pre className="p-4 text-xs font-mono text-slate-200 whitespace-pre overflow-auto h-full leading-relaxed">
			{text}
		</pre>
	);
}
