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
