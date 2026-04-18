import { create } from "zustand";
import JSON5 from "json5";
import { parseLine } from "./trace/parse";
import { TraceBuilder, emptyModel, type TraceModel } from "./trace/model";
import { buildRoundtrippedText } from "./config/roundtrip";
import type { DocsResponse } from "../shared/types";

type RunStatus = "idle" | "running" | "done" | "error";
type ConfigStatus = "idle" | "loading" | "loaded" | "error";
// FIXME(v1.0.0): add a proper light theme using Tailwind darkMode: 'class' —
// requires adding dark: prefixes to all color classes across all components.
export type Theme = "slate" | "zinc";

const THEME_STORAGE_KEY = "bxp-ui.theme";

function readStoredTheme(): Theme {
	if (typeof localStorage === "undefined") return "zinc";
	const v = localStorage.getItem(THEME_STORAGE_KEY);
	return v === "slate" ? "slate" : "zinc";
}

function applyTheme(t: Theme): void {
	if (typeof document === "undefined") return;
	if (t === "slate") document.documentElement.removeAttribute("data-theme");
	else document.documentElement.setAttribute("data-theme", t);
}

export type PathSeg = string | number;

// Immutable set-at-path: returns a shallow-copied spine with `value` installed
// at `path`. Used to produce a fresh draft on every edit so zustand/React
// notice the change via reference equality.
function setAtPath(obj: unknown, path: readonly PathSeg[], value: unknown): unknown {
	if (path.length === 0) return value;
	const head = path[0];
	const rest = path.slice(1);
	if (typeof head === "number" && Array.isArray(obj)) {
		const copy = obj.slice();
		copy[head] = setAtPath(obj[head], rest, value);
		return copy;
	}
	if (
		typeof head === "string" &&
		obj !== null &&
		typeof obj === "object" &&
		!Array.isArray(obj)
	) {
		const copy = { ...(obj as Record<string, unknown>) };
		copy[head] = setAtPath(
			(obj as Record<string, unknown>)[head],
			rest,
			value,
		);
		return copy;
	}
	return obj;
}

// Immutable transform-at-path: returns a shallow-copied spine where the
// container at `path` has been passed through `transform`. Used by
// structural edits (insert / delete / move / duplicate) so each produces
// exactly one history entry with one new spine.
function transformAtPath(
	obj: unknown,
	path: readonly PathSeg[],
	transform: (container: unknown) => unknown,
): unknown {
	if (path.length === 0) return transform(obj);
	const head = path[0];
	const rest = path.slice(1);
	if (typeof head === "number" && Array.isArray(obj)) {
		const copy = obj.slice();
		copy[head] = transformAtPath(obj[head], rest, transform);
		return copy;
	}
	if (
		typeof head === "string" &&
		obj !== null &&
		typeof obj === "object" &&
		!Array.isArray(obj)
	) {
		const copy = { ...(obj as Record<string, unknown>) };
		copy[head] = transformAtPath(
			(obj as Record<string, unknown>)[head],
			rest,
			transform,
		);
		return copy;
	}
	return obj;
}

// Pick a key name not already present in `src`, starting from `base_copy`
// and appending incrementing numeric suffixes if needed. Used when the
// user duplicates an object entry without providing an explicit new key.
function uniqueKey(src: Record<string, unknown>, base: string): string {
	const stem = `${base}_copy`;
	if (!(stem in src)) return stem;
	for (let i = 2; i < 10_000; i++) {
		const candidate = `${stem}${i}`;
		if (!(candidate in src)) return candidate;
	}
	return `${stem}_${Date.now()}`;
}

function cloneDeep<T>(v: T): T {
	if (Array.isArray(v)) return v.map(cloneDeep) as unknown as T;
	if (v !== null && typeof v === "object") {
		const out: Record<string, unknown> = {};
		for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
			out[k] = cloneDeep(val);
		}
		return out as T;
	}
	return v;
}

type Rpc = {
	request: {
		runDryRun: (args: {
			configPath: string;
			templateId?: string;
		}) => Promise<{ exitCode: number; stderr: string }>;
		loadConfig: (args: {
			path: string;
		}) => Promise<{ rawText: string; validationError: string | null }>;
		saveConfig: (args: {
			path: string;
			text: string;
		}) => Promise<{ ok: boolean; error: string | null }>;
		validateExpr: (args: {
			expr: string;
		}) => Promise<{ ok: boolean; error: string | null }>;
		openInEditor: (args: {
			path: string;
		}) => Promise<{ ok: boolean }>;
		openUrl: (args: {
			url: string;
		}) => Promise<{ ok: boolean }>;
		openFileDialog: (args: Record<string, never>) => Promise<{ path: string | null }>;
		getStartupConfig: (args: Record<string, never>) => Promise<{ path: string | null }>;
		getDocs: (args: Record<string, never>) => Promise<DocsResponse | null>;
	};
};

type TraceStore = {
	// Form inputs
	configPath: string;
	templateId: string;
	setConfigPath: (s: string) => void;
	setTemplateId: (s: string) => void;

	// Theme (Phase 6 polish). `"slate"` = default blue-tinted dark palette,
	// `"zinc"` = neutral dark gray. Persisted to localStorage and applied to
	// <html data-theme="..."> so Tailwind's slate-* classes (remapped to CSS
	// vars in tailwind.config.js) swap palette without any component change.
	theme: Theme;
	setTheme: (t: Theme) => void;
	toggleTheme: () => void;

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
	configSaveStatus: "idle" | "saving" | "saved" | "error";
	configSaveError: string | null;
	loadConfig: () => Promise<void>;
	saveDraft: () => Promise<void>;

	// Editable config draft + undo/redo (Phase 6). `originalConfig` is pinned
	// to the last-loaded parse; `draftConfig` is the current user-edited state.
	// `draftHistory` / `draftFuture` hold whole-object snapshots — cheap because
	// setAtPath copies only the spine, so shared subtrees stay alive.
	originalConfig: unknown;
	draftConfig: unknown;
	draftHistory: unknown[];
	draftFuture: unknown[];
	editLeaf: (path: readonly PathSeg[], value: unknown) => void;
	// Structural edits. `parentPath` points at the container (object/array),
	// `key` is a string for objects and a number index for arrays. All of
	// these push a history entry and clear the redo future.
	insertChild: (
		parentPath: readonly PathSeg[],
		key: PathSeg,
		value: unknown,
	) => void;
	deleteChild: (parentPath: readonly PathSeg[], key: PathSeg) => void;
	moveChild: (
		parentPath: readonly PathSeg[],
		fromIndex: number,
		toIndex: number,
	) => void;
	duplicateChild: (
		parentPath: readonly PathSeg[],
		key: PathSeg,
		newKey?: string,
	) => void;
	undo: () => void;
	redo: () => void;
	resetDraft: () => void;

	// Expression validation (Phase 5)
	validateExpr: (expr: string) => Promise<{ ok: boolean; error: string | null }>;
	openInEditor: (path: string) => Promise<void>;
	openUrl: (url: string) => Promise<void>;
	openFileDialog: () => Promise<string | null>;

	// Selection
	selectedFileId: string | null;
	selectedRowId: string | null;
	selectFile: (id: string | null) => void;
	selectRow: (id: string | null) => void;

	// Docs loaded from bxp-fmt --docs (single source of truth)
	docs: DocsResponse | null;

	// Selected expr leaf (Config tab — drives the right panel editor)
	selectedExprPath: readonly PathSeg[] | null;
	selectedExprText: string;
	setSelectedExpr: (path: readonly PathSeg[], text: string) => void;
	clearSelectedExpr: () => void;

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
		configPath: "",
		templateId: "",
		setConfigPath: (s) => set({ configPath: s }),
		setTemplateId: (s) => set({ templateId: s }),

		theme: (() => {
			const t = readStoredTheme();
			applyTheme(t);
			return t;
		})(),
		setTheme: (t) => {
			applyTheme(t);
			try {
				localStorage.setItem(THEME_STORAGE_KEY, t);
			} catch {}
			set({ theme: t });
		},
		toggleTheme: () => {
			get().setTheme(get().theme === "slate" ? "zinc" : "slate");
		},

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
		configSaveStatus: "idle",
		configSaveError: null,

		originalConfig: null,
		draftConfig: null,
		draftHistory: [],
		draftFuture: [],

		loadConfig: async () => {
			if (!rpc) {
				set({ configStatus: "error", configError: "RPC not attached" });
				return;
			}
			const path = get().configPath;
			if (!path) {
				set({ configStatus: "idle" });
				return;
			}
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
					originalConfig: parsed,
					draftConfig: parsed,
					draftHistory: [],
					draftFuture: [],
				});
			} catch (e) {
				set({
					configStatus: "error",
					configError: e instanceof Error ? e.message : String(e),
				});
			}
		},

		saveDraft: async () => {
			if (!rpc) {
				set({ configSaveStatus: "error", configSaveError: "RPC not attached" });
				return;
			}
			const s = get();
			if (s.draftConfig === null) return;
			const text = buildRoundtrippedText(
				s.configText,
				s.originalConfig,
				s.draftConfig,
				(v) => JSON5.stringify(v, null, 2),
			);
			set({ configSaveStatus: "saving", configSaveError: null });
			try {
				const res = await rpc.request.saveConfig({
					path: s.configPath,
					text,
				});
				if (!res.ok) {
					set({
						configSaveStatus: "error",
						configSaveError: res.error ?? "save failed",
					});
					return;
				}
				set({ configSaveStatus: "saved", configSaveError: null });
				// Reload from disk so bxp-fmt validation re-runs and
				// originalConfig/configText pick up any on-disk normalization.
				// This also resets the undo history — intentional, the saved
				// state is the new baseline.
				await get().loadConfig();
			} catch (e) {
				set({
					configSaveStatus: "error",
					configSaveError: e instanceof Error ? e.message : String(e),
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

		openInEditor: async (path) => {
			if (!rpc) return;
			try {
				await rpc.request.openInEditor({ path });
			} catch {
				// ignore
			}
		},

		openUrl: async (url) => {
			if (!rpc) return;
			try {
				await rpc.request.openUrl({ url });
			} catch {
				// ignore
			}
		},

		openFileDialog: async () => {
			if (!rpc) return null;
			try {
				const res = await rpc.request.openFileDialog({});
				return res.path;
			} catch {
				return null;
			}
		},

		editLeaf: (path, value) =>
			set((s) => {
				const next = setAtPath(s.draftConfig, path, value);
				if (next === s.draftConfig) return {};
				return {
					draftConfig: next,
					draftHistory: [...s.draftHistory, s.draftConfig],
					draftFuture: [],
				};
			}),

		insertChild: (parentPath, key, value) =>
			set((s) => {
				const next = transformAtPath(s.draftConfig, parentPath, (container) => {
					if (Array.isArray(container)) {
						if (typeof key !== "number") return container;
						const copy = container.slice();
						const idx = Math.max(0, Math.min(key, copy.length));
						copy.splice(idx, 0, value);
						return copy;
					}
					if (container !== null && typeof container === "object") {
						if (typeof key !== "string" || key.length === 0) return container;
						if (key in (container as Record<string, unknown>)) return container;
						return { ...(container as Record<string, unknown>), [key]: value };
					}
					return container;
				});
				if (next === s.draftConfig) return {};
				return {
					draftConfig: next,
					draftHistory: [...s.draftHistory, s.draftConfig],
					draftFuture: [],
				};
			}),

		deleteChild: (parentPath, key) =>
			set((s) => {
				const next = transformAtPath(s.draftConfig, parentPath, (container) => {
					if (Array.isArray(container)) {
						if (typeof key !== "number") return container;
						if (key < 0 || key >= container.length) return container;
						const copy = container.slice();
						copy.splice(key, 1);
						return copy;
					}
					if (container !== null && typeof container === "object") {
						if (typeof key !== "string") return container;
						const src = container as Record<string, unknown>;
						if (!(key in src)) return container;
						const copy: Record<string, unknown> = {};
						for (const [k, v] of Object.entries(src)) {
							if (k !== key) copy[k] = v;
						}
						return copy;
					}
					return container;
				});
				if (next === s.draftConfig) return {};
				return {
					draftConfig: next,
					draftHistory: [...s.draftHistory, s.draftConfig],
					draftFuture: [],
				};
			}),

		moveChild: (parentPath, fromIndex, toIndex) =>
			set((s) => {
				const next = transformAtPath(s.draftConfig, parentPath, (container) => {
					if (!Array.isArray(container)) return container;
					if (
						fromIndex < 0 ||
						fromIndex >= container.length ||
						toIndex < 0 ||
						toIndex >= container.length ||
						fromIndex === toIndex
					) {
						return container;
					}
					const copy = container.slice();
					const [item] = copy.splice(fromIndex, 1);
					copy.splice(toIndex, 0, item);
					return copy;
				});
				if (next === s.draftConfig) return {};
				return {
					draftConfig: next,
					draftHistory: [...s.draftHistory, s.draftConfig],
					draftFuture: [],
				};
			}),

		duplicateChild: (parentPath, key, newKey) =>
			set((s) => {
				const next = transformAtPath(s.draftConfig, parentPath, (container) => {
					if (Array.isArray(container)) {
						if (typeof key !== "number") return container;
						if (key < 0 || key >= container.length) return container;
						const copy = container.slice();
						copy.splice(key + 1, 0, cloneDeep(container[key]));
						return copy;
					}
					if (container !== null && typeof container === "object") {
						if (typeof key !== "string") return container;
						const src = container as Record<string, unknown>;
						if (!(key in src)) return container;
						const target =
							newKey && newKey.length > 0 && !(newKey in src)
								? newKey
								: uniqueKey(src, key);
						// Insert immediately after the source key to keep neighbors
						// grouped visually in the tree (object order matters for our
						// config files: templates sit next to their siblings).
						const copy: Record<string, unknown> = {};
						for (const [k, v] of Object.entries(src)) {
							copy[k] = v;
							if (k === key) copy[target] = cloneDeep(v);
						}
						return copy;
					}
					return container;
				});
				if (next === s.draftConfig) return {};
				return {
					draftConfig: next,
					draftHistory: [...s.draftHistory, s.draftConfig],
					draftFuture: [],
				};
			}),

		undo: () =>
			set((s) => {
				if (s.draftHistory.length === 0) return {};
				const prev = s.draftHistory[s.draftHistory.length - 1];
				return {
					draftConfig: prev,
					draftHistory: s.draftHistory.slice(0, -1),
					draftFuture: [s.draftConfig, ...s.draftFuture],
				};
			}),

		redo: () =>
			set((s) => {
				if (s.draftFuture.length === 0) return {};
				const next = s.draftFuture[0];
				return {
					draftConfig: next,
					draftHistory: [...s.draftHistory, s.draftConfig],
					draftFuture: s.draftFuture.slice(1),
				};
			}),

		resetDraft: () =>
			set((s) => ({
				draftConfig: s.originalConfig,
				draftHistory: [],
				draftFuture: [],
			})),

		selectedFileId: null,
		selectedRowId: null,
		selectFile: (id) => set({ selectedFileId: id, selectedRowId: null }),
		selectRow: (id) => set({ selectedRowId: id }),

		docs: null,

		selectedExprPath: null,
		selectedExprText: "",
		setSelectedExpr: (path, text) => set({ selectedExprPath: path, selectedExprText: text }),
		clearSelectedExpr: () => set({ selectedExprPath: null, selectedExprText: "" }),

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
			// Load docs from bxp-fmt --docs
			r.request.getDocs({}).then((docs) => {
				if (docs) set({ docs });
			}).catch(() => {});
			// Auto-load bxp-cli.json from cwd if present
			r.request.getStartupConfig({}).then(({ path }) => {
				if (path) {
					set({ configPath: path });
					get().loadConfig();
				}
			}).catch(() => {});
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
