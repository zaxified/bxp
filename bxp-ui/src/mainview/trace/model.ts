import type {
	FileEndEvent,
	FileStartEvent,
	PrepassSetEvent,
	RowOutputEvent,
	RuleMatchEvent,
	RuleNoMatchEvent,
	StartEvent,
	TraceEvent,
	VarErrorEvent,
	VarEvalEvent,
} from "./types";

export type VarEntry =
	| { kind: "eval"; name: string; expr: string; value: string }
	| {
			kind: "error";
			name: string;
			expr: string;
			error: string;
			detail?: string;
	  };

export type RuleEntry = {
	ruleIndex: number;
	when: string;
	matched: boolean;
};

export type RowModel = {
	id: string;
	fileId: string;
	fileRow: number;
	fields: string[];
	vars: VarEntry[];
	rules: RuleEntry[];
	filteredReason: string | null;
	output: string[] | null;
	matchedRuleIndex: number | null;
	hasError: boolean;
};

export type FileModel = {
	id: string;
	template: string;
	path: string;
	rows: number;
	headers: string[];
	prepass: PrepassSetEvent[];
	rowIds: string[];
	stats: FileEndEvent["stats"] | null;
};

export type TraceModel = {
	start: StartEvent | null;
	done: { exitCode: number } | null;
	files: Record<string, FileModel>;
	fileOrder: string[];
	rows: Record<string, RowModel>;
	issues: string[]; // parse errors, unknown event types, etc.
};

export function emptyModel(): TraceModel {
	return {
		start: null,
		done: null,
		files: {},
		fileOrder: [],
		rows: {},
		issues: [],
	};
}

// Mutable builder. The store clones the model before each batch apply so
// React re-renders see a new reference.
export class TraceBuilder {
	model: TraceModel;
	private currentFileId: string | null = null;
	private currentRowId: string | null = null;
	private rowCounter = 0;

	constructor(model?: TraceModel) {
		this.model = model ?? emptyModel();
	}

	apply(ev: TraceEvent): void {
		switch (ev.t) {
			case "start":
				this.applyStart(ev);
				break;
			case "file_start":
				this.applyFileStart(ev);
				break;
			case "prepass_set":
				this.applyPrepassSet(ev);
				break;
			case "row_start":
				this.applyRowStart(ev);
				break;
			case "var_eval":
				this.applyVarEval(ev);
				break;
			case "var_error":
				this.applyVarError(ev);
				break;
			case "rule_match":
				this.applyRuleMatch(ev, true);
				break;
			case "rule_no_match":
				this.applyRuleMatch(ev, false);
				break;
			case "row_filtered":
				this.applyRowFiltered(ev.reason);
				break;
			case "row_output":
				this.applyRowOutput(ev);
				break;
			case "row_end":
				this.currentRowId = null;
				break;
			case "file_end":
				this.applyFileEnd(ev);
				break;
			case "done":
				this.model.done = { exitCode: ev.exit_code };
				break;
		}
	}

	addIssue(s: string) {
		this.model.issues.push(s);
	}

	private applyStart(ev: StartEvent) {
		this.model.start = ev;
	}

	private applyFileStart(ev: FileStartEvent) {
		const id = `${ev.template}::${ev.path}`;
		const file: FileModel = {
			id,
			template: ev.template,
			path: ev.path,
			rows: ev.rows,
			headers: ev.headers,
			prepass: [],
			rowIds: [],
			stats: null,
		};
		this.model.files[id] = file;
		this.model.fileOrder.push(id);
		this.currentFileId = id;
	}

	private applyPrepassSet(ev: PrepassSetEvent) {
		const file = this.currentFileId
			? this.model.files[this.currentFileId]
			: null;
		file?.prepass.push(ev);
	}

	private applyRowStart(ev: { file_row: number; fields: string[] }) {
		if (!this.currentFileId) return;
		const id = `r${this.rowCounter++}`;
		const row: RowModel = {
			id,
			fileId: this.currentFileId,
			fileRow: ev.file_row,
			fields: ev.fields,
			vars: [],
			rules: [],
			filteredReason: null,
			output: null,
			matchedRuleIndex: null,
			hasError: false,
		};
		this.model.rows[id] = row;
		this.model.files[this.currentFileId].rowIds.push(id);
		this.currentRowId = id;
	}

	private row(): RowModel | null {
		return this.currentRowId ? this.model.rows[this.currentRowId] : null;
	}

	private applyVarEval(ev: VarEvalEvent) {
		const row = this.row();
		if (!row) return;
		row.vars.push({
			kind: "eval",
			name: ev.name,
			expr: ev.expr,
			value: ev.value,
		});
	}

	private applyVarError(ev: VarErrorEvent) {
		const row = this.row();
		if (!row) return;
		row.vars.push({
			kind: "error",
			name: ev.name,
			expr: ev.expr,
			error: ev.error,
			detail: ev.detail,
		});
		row.hasError = true;
	}

	private applyRuleMatch(
		ev: RuleMatchEvent | RuleNoMatchEvent,
		matched: boolean,
	) {
		const row = this.row();
		if (!row) return;
		row.rules.push({
			ruleIndex: ev.rule_index,
			when: ev.when,
			matched,
		});
		if (matched && row.matchedRuleIndex === null) {
			row.matchedRuleIndex = ev.rule_index;
		}
	}

	private applyRowFiltered(reason: string) {
		const row = this.row();
		if (!row) return;
		row.filteredReason = reason;
	}

	private applyRowOutput(ev: RowOutputEvent) {
		const row = this.row();
		if (!row) return;
		row.output = ev.values;
	}

	private applyFileEnd(ev: FileEndEvent) {
		const file = this.model.files[`${ev.template}::${ev.path}`];
		if (file) file.stats = ev.stats;
		this.currentFileId = null;
	}
}
