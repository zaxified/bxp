import type { RPCSchema } from "electrobun/bun";

export type RunDryRunParams = {
	configPath: string;
	templateId?: string;
};

export type RunDryRunResponse = {
	exitCode: number;
	stderr: string;
};

export type LoadConfigParams = {
	path: string;
};

export type LoadConfigResponse = {
	rawText: string;
	validationError: string | null;
};

export type SaveConfigParams = {
	path: string;
	text: string;
};

export type SaveConfigResponse = {
	ok: boolean;
	error: string | null;
};

export type ValidateExprParams = {
	expr: string;
};

export type ValidateExprResponse = {
	ok: boolean;
	error: string | null;
};

export type OpenInEditorParams = {
	path: string;
};

export type OpenInEditorResponse = {
	ok: boolean;
};

export type OpenUrlParams = {
	url: string;
};

export type OpenFileDialogResponse = {
	path: string | null;
};

export type GetStartupConfigResponse = {
	path: string | null;
};

export type FnDoc = {
	name: string;
	signature: string;
	description: string;
};

export type KeywordDoc = {
	name: string;
	description: string;
};

export type OperatorDoc = {
	token: string;
	description: string;
};

export type TokenDoc = {
	kind: string;
	syntax: string;
	description: string;
};

export type FieldDoc = {
	key: string;
	type_name: string;
	required: boolean;
	default: string | null;
	description: string;
};

export type DocsResponse = {
	functions: FnDoc[];
	keywords: KeywordDoc[];
	operators: OperatorDoc[];
	tokens: TokenDoc[];
	config_schema: FieldDoc[];
};

export type GetDocsResponse = DocsResponse | null;

export type TraceEventMsg = {
	line: string;
};

export type StderrMsg = {
	chunk: string;
};

export type AppRPCType = {
	bun: RPCSchema<{
		requests: {
			runDryRun: {
				params: RunDryRunParams;
				response: RunDryRunResponse;
			};
			loadConfig: {
				params: LoadConfigParams;
				response: LoadConfigResponse;
			};
			saveConfig: {
				params: SaveConfigParams;
				response: SaveConfigResponse;
			};
			validateExpr: {
				params: ValidateExprParams;
				response: ValidateExprResponse;
			};
			openInEditor: {
				params: OpenInEditorParams;
				response: OpenInEditorResponse;
			};
			openUrl: {
				params: OpenUrlParams;
				response: OpenInEditorResponse;
			};
			openFileDialog: {
				params: Record<string, never>;
				response: OpenFileDialogResponse;
			};
			getStartupConfig: {
				params: Record<string, never>;
				response: GetStartupConfigResponse;
			};
			getDocs: {
				params: Record<string, never>;
				response: GetDocsResponse;
			};
		};
		messages: Record<string, never>;
	}>;
	webview: RPCSchema<{
		requests: Record<string, never>;
		messages: {
			traceEvent: TraceEventMsg;
			stderr: StderrMsg;
		};
	}>;
};
