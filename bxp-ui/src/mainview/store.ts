import { create } from "zustand";
import JSON5 from "json5";
import { parseLine } from "./trace/parse";
import { TraceBuilder, emptyModel, type TraceModel } from "./trace/model";

type RunStatus = "idle" | "running" | "done" | "error";
type ConfigStatus = "idle" | "loading" | "loaded" | "error";

type Rpc = {
	request: {
		runDryRun: (args: {
			configPath: string;
			templateId?: string;
		}) => Promise<{ exitCode: number; stderr: string }>;
		loadConfig: (args: {
			path: string;
		}) => Promise<{ rawText: string; validationError: string | null }>;
		validateExpr: (args: {
			expr: string;
		}) => Promise<{ ok: boolean; error: string | null }>;
	};
};

type TraceStore = {
	// Form inputs
	configPath: string;
	templateId: string;
	setConfigPath: (s: string) => void;
	setTemplateId: (s: string) => void;

	// Runtime state
	status: RunStatus;
	runError: string | null;
	stderr: string;
	rawLines: number;

	// Parsed model. Builder mutates in place; modelVersion increments on every
	// committed batch so components subscribed to it re-render and re-read
	// nested state whose references stay stable across mutations.
	model: TraceModel;
	modelVersion: number;

	// Config state (Phase 4)
	configStatus: ConfigStatus;
	configText: string;
	configParsed: unknown;
	configError: string | null;
	configValidationError: string | null;
	loadConfig: () => Promise<void>;

	// Expression validation (Phase 5)
	validateExpr: (expr: string) => Promise<{ ok: boolean; error: string | null }>;

	// Selection
	selectedFileId: string | null;
	selectedRowId: string | null;
	selectFile: (id: string | null) => void;
	selectRow: (id: string | null) => void;

	// Ingestion
	pushLine: (line: string) => void;
	pushStderr: (chunk: string) => void;
	attachRpc: (rpc: Rpc) => void;
	runDryRun: () => Promise<void>;
};

export const useTraceStore = create<TraceStore>((set, get) => {
	let builder = new TraceBuilder();
	let rpc: Rpc | null = null;
	// Batch line flushes at ~60Hz so bursts of NDJSON don't cause 1 render per line.
	let pendingFlush: ReturnType<typeof setTimeout> | null = null;
	const scheduleFlush = () => {
		if (pendingFlush !== null) return;
		pendingFlush = setTimeout(() => {
			pendingFlush = null;
			set((s) => ({
				model: { ...builder.model },
				modelVersion: s.modelVersion + 1,
			}));
		}, 16);
	};

	const resetBuilder = () => {
		builder = new TraceBuilder(emptyModel());
	};

	return {
		configPath: "/home/zak/workspace/zig/bxp/DEV/bxp-cli.json",
		templateId: "",
		setConfigPath: (s) => set({ configPath: s }),
		setTemplateId: (s) => set({ templateId: s }),

		status: "idle",
		runError: null,
		stderr: "",
		rawLines: 0,

		model: builder.model,
		modelVersion: 0,

		configStatus: "idle",
		configText: "",
		configParsed: null,
		configError: null,
		configValidationError: null,

		loadConfig: async () => {
			if (!rpc) {
				set({ configStatus: "error", configError: "RPC not attached" });
				return;
			}
			const path = get().configPath;
			set({
				configStatus: "loading",
				configError: null,
				configValidationError: null,
			});
			try {
				const { rawText, validationError } = await rpc.request.loadConfig({
					path,
				});
				let parsed: unknown = null;
				let parseError: string | null = null;
				try {
					parsed = JSON5.parse(rawText);
				} catch (e) {
					parseError = e instanceof Error ? e.message : String(e);
				}
				set({
					configStatus: parseError ? "error" : "loaded",
					configText: rawText,
					configParsed: parsed,
					configError: parseError,
					configValidationError: validationError,
				});
			} catch (e) {
				set({
					configStatus: "error",
					configError: e instanceof Error ? e.message : String(e),
				});
			}
		},

		validateExpr: async (expr) => {
			if (!rpc) return { ok: false, error: "RPC not attached" };
			try {
				return await rpc.request.validateExpr({ expr });
			} catch (e) {
				return { ok: false, error: e instanceof Error ? e.message : String(e) };
			}
		},

		selectedFileId: null,
		selectedRowId: null,
		selectFile: (id) => set({ selectedFileId: id, selectedRowId: null }),
		selectRow: (id) => set({ selectedRowId: id }),

		pushLine: (line) => {
			const res = parseLine(line);
			if (res.kind === "invalid") {
				builder.addIssue(`invalid NDJSON: ${res.error} :: ${res.raw}`);
			} else if (res.kind === "event") {
				builder.apply(res.event);
				// Auto-select the first file so the UI has something to show.
				const st = get();
				if (
					res.event.t === "file_start" &&
					st.selectedFileId === null &&
					builder.model.fileOrder.length > 0
				) {
					set({ selectedFileId: builder.model.fileOrder[0] });
				}
			}
			set((s) => ({ rawLines: s.rawLines + 1 }));
			scheduleFlush();
		},

		pushStderr: (chunk) => set((s) => ({ stderr: s.stderr + chunk })),

		attachRpc: (r) => {
			rpc = r;
		},

		runDryRun: async () => {
			if (!rpc) {
				set({ status: "error", runError: "RPC not attached" });
				return;
			}
			resetBuilder();
			set((s) => ({
				status: "running",
				runError: null,
				stderr: "",
				rawLines: 0,
				model: builder.model,
				modelVersion: s.modelVersion + 1,
				selectedFileId: null,
				selectedRowId: null,
			}));
			const { configPath, templateId } = get();
			try {
				await rpc.request.runDryRun({
					configPath,
					templateId: templateId.length > 0 ? templateId : undefined,
				});
				// Flush any pending batch so model reflects the full run.
				if (pendingFlush !== null) {
					clearTimeout(pendingFlush);
					pendingFlush = null;
				}
				set((s) => ({
					status: "done",
					model: { ...builder.model },
					modelVersion: s.modelVersion + 1,
				}));
			} catch (e) {
				set({
					status: "error",
					runError: e instanceof Error ? e.message : String(e),
				});
			}
		},
	};
});
