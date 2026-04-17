// NDJSON trace event shapes emitted by `bxp-cli --trace` (schema_version = 1).
// Keep in sync with bxp/bxp-cli/src/pipeline.zig event emitters.

export type StartEvent = {
	t: "start";
	schema_version: number;
	config: string;
	templates: string[];
};

export type FileStartEvent = {
	t: "file_start";
	template: string;
	path: string;
	rows: number;
	headers: string[];
};

export type PrepassSetEvent = {
	t: "prepass_set";
	key: string;
	field: string;
	value: string;
};

export type RowStartEvent = {
	t: "row_start";
	file_row: number;
	fields: string[];
};

export type VarEvalEvent = {
	t: "var_eval";
	name: string;
	expr: string;
	value: string;
};

export type VarErrorEvent = {
	t: "var_error";
	name: string;
	expr: string;
	error: string;
	detail?: string;
};

export type RuleMatchEvent = {
	t: "rule_match";
	rule_index: number;
	when: string;
};

export type RuleNoMatchEvent = {
	t: "rule_no_match";
	rule_index: number;
	when: string;
};

export type RowFilteredEvent = {
	t: "row_filtered";
	reason: string;
};

export type RowOutputEvent = {
	t: "row_output";
	values: string[];
};

export type RowEndEvent = {
	t: "row_end";
};

export type FileEndEvent = {
	t: "file_end";
	template: string;
	path: string;
	stats: {
		rows: number;
		written: number;
		errors: number;
		warnings: number;
	};
};

export type DoneEvent = {
	t: "done";
	exit_code: number;
};

export type TraceEvent =
	| StartEvent
	| FileStartEvent
	| PrepassSetEvent
	| RowStartEvent
	| VarEvalEvent
	| VarErrorEvent
	| RuleMatchEvent
	| RuleNoMatchEvent
	| RowFilteredEvent
	| RowOutputEvent
	| RowEndEvent
	| FileEndEvent
	| DoneEvent;

export type UnknownEvent = { t: string; [k: string]: unknown };
