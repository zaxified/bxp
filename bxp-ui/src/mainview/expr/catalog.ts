export type FnDoc = {
	name: string;
	signature: string;
	description: string;
};

// Mirrors bxp-core/src/expr.zig. Update in lockstep when the evaluator gains
// new functions. Descriptions are concise — the goal is Monaco hover docs.
export const BXP_FUNCTIONS: readonly FnDoc[] = [
	{
		name: "IF",
		signature: "IF(cond, yes, no)",
		description: "Short-circuit conditional. Returns `yes` if `cond` is truthy, else `no`.",
	},
	{
		name: "ABS",
		signature: "ABS(f)",
		description: "Absolute numeric value.",
	},
	{
		name: "NOW",
		signature: "NOW()",
		description: "Current UTC datetime as ISO 8601 string (`YYYY-MM-DDTHH:MM:SSZ`).",
	},
	{
		name: "TRIM",
		signature: "TRIM(f)",
		description: "Strip leading and trailing whitespace from a string.",
	},
	{
		name: "ROUND",
		signature: "ROUND(f, n)",
		description: "Round `f` to `n` decimal places.",
	},
	{
		name: "FLOOR",
		signature: "FLOOR(f)",
		description: "Round `f` down to nearest integer.",
	},
	{
		name: "CEILING",
		signature: "CEILING(f)",
		description: "Round `f` up to nearest integer.",
	},
	{
		name: "RAND",
		signature: "RAND()",
		description: "Random float in `[0, 1)`.",
	},
	{
		name: "COALESCE",
		signature: "COALESCE(a, b, ...)",
		description: "First non-empty argument (empty = whitespace-only string).",
	},
	{
		name: "DATE_CONVERT",
		signature: "DATE_CONVERT(f, from, to)",
		description: "Reformat a date/time string. Format tokens use sunrise syntax (e.g. `%Y-%m-%d`).",
	},
	{
		name: "PRICE_VALUE",
		signature: "PRICE_VALUE(f)",
		description: "Strip currency symbol/code, return numeric string.",
	},
	{
		name: "PRICE_CURRENCY",
		signature: "PRICE_CURRENCY(f)",
		description: "Extract currency code from a price string.",
	},
	{
		name: "TICKER",
		signature: "TICKER(f)",
		description: "Map field value through broker's `ticker_map`.",
	},
	{
		name: "LOOKUP",
		signature: "LOOKUP(key, field)",
		description: "Retrieve a value stored by the `pre_pass` table.",
	},
	{
		name: "SPLIT_PART",
		signature: "SPLIT_PART(s, delim, n)",
		description: "Return the n-th part of a delimited string (1-based).",
	},
	{
		name: "CONTAINS",
		signature: "CONTAINS(haystack, needle)",
		description: "Boolean: does `haystack` contain `needle`?",
	},
	{
		name: "REPLACE",
		signature: "REPLACE(s, from, to)",
		description: "Replace all occurrences of `from` in `s` with `to`.",
	},
	{
		name: "FIELDS",
		signature: "FIELDS(n)",
		description: "Field value by 1-based column index (alternative to `[ColumnName]`).",
	},
];

export const BXP_KEYWORDS = ["AND", "OR"] as const;

export const FUNCTION_NAMES: readonly string[] = BXP_FUNCTIONS.map((f) => f.name);
