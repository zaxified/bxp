// Single source of truth for bxp-expr syntax colors.
// Used by: language.ts (CM6), highlight.tsx (React inline), ExprPanel.tsx (docs catalog).
export const C = {
	function:    "#c4b5fd",  // violet-300
	keyword:     "#60a5fa",  // blue-400
	columnRef:   "#fbbf24",  // amber-400
	inputVar:    "#a78bfa",  // violet-400
	string:      "#6ee7b7",  // emerald-300
	number:      "#fcd34d",  // amber-300
	operator:    "#94a3b8",  // slate-400
	punctuation: "#64748b",  // slate-500
	ident:       "#e2e8f0",  // slate-200
} as const;
