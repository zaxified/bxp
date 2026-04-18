import { BrowserView, BrowserWindow, Updater } from "electrobun/bun";
import { dlopen, FFIType, ptr } from "bun:ffi";
import { resolve, dirname } from "node:path";
import { existsSync } from "node:fs";
import { rename, unlink, copyFile, access } from "node:fs/promises";
import type { AppRPCType } from "../shared/types";

const DEV_SERVER_PORT = 5173;
const DEV_SERVER_URL = `http://localhost:${DEV_SERVER_PORT}`;

// Resolve a sibling Zig binary. Three strategies, in priority order:
//  1. Env override (BXP_CLI_PATH / BXP_FMT_PATH) — takes precedence.
//  2. Packaged bundle: Resources/app/bin/<binName> relative to import.meta.dir.
//     Electrobun ships app code under Resources/app/bun and we co-locate the
//     Zig binaries under Resources/app/bin. Empty until the release flow wires
//     the copy step (see README), but the resolver is ready.
//  3. Dev / source tree: walk up from import.meta.dir and process.cwd(),
//     looking for the matching zig-out path (works from both the repo root
//     and the Electrobun build/dev-linux-*/ run location).
function findSiblingBin(
	binName: string,
	devRelPath: string,
	envOverride?: string,
): string {
	if (envOverride) return envOverride;

	const tried: string[] = [];

	// Packaged bundle: sibling Resources/app/bin/<binName>
	{
		const packaged = resolve(import.meta.dir, "..", "bin", binName);
		tried.push(packaged);
		if (existsSync(packaged)) return packaged;
	}

	// Dev: walk up looking for bxp-cli/zig-out/bin/bxp-cli etc.
	const starts = [import.meta.dir, process.cwd()];
	for (const start of starts) {
		let dir = start;
		for (let i = 0; i < 8; i++) {
			const candidate = resolve(dir, devRelPath);
			tried.push(candidate);
			if (existsSync(candidate)) return candidate;
			const parent = dirname(dir);
			if (parent === dir) break;
			dir = parent;
		}
	}

	console.error(
		`[bxp-ui] ${binName} not found.\nTried:\n  ${tried.join("\n  ")}`,
	);
	return binName;
}

const BXP_CLI_PATH = findSiblingBin(
	"bxp-cli",
	"bxp-cli/zig-out/bin/bxp-cli",
	process.env.BXP_CLI_PATH,
);
const BXP_FMT_PATH = findSiblingBin(
	"bxp-fmt",
	"bxp-fmt/zig-out/bin/bxp-fmt",
	process.env.BXP_FMT_PATH,
);
console.log(`[bxp-ui] bxp-cli: ${BXP_CLI_PATH}`);
console.log(`[bxp-ui] bxp-fmt: ${BXP_FMT_PATH}`);

async function getMainViewUrl(): Promise<string> {
	const channel = await Updater.localInfo.channel();
	if (channel === "dev") {
		try {
			await fetch(DEV_SERVER_URL, { method: "HEAD" });
			console.log(`HMR enabled: using Vite dev server at ${DEV_SERVER_URL}`);
			return DEV_SERVER_URL;
		} catch {
			console.log(
				"Vite dev server not running. Run 'bun run dev:hmr' for HMR support.",
			);
		}
	}
	return "views://mainview/index.html";
}

// Stream a ReadableStream<Uint8Array> line-by-line (lines are stripped of trailing '\n').
async function streamLines(
	stream: ReadableStream<Uint8Array>,
	onLine: (line: string) => void,
): Promise<void> {
	const decoder = new TextDecoder();
	const reader = stream.getReader();
	let buf = "";
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		buf += decoder.decode(value, { stream: true });
		let nl = buf.indexOf("\n");
		while (nl >= 0) {
			onLine(buf.slice(0, nl));
			buf = buf.slice(nl + 1);
			nl = buf.indexOf("\n");
		}
	}
	buf += decoder.decode();
	if (buf.length > 0) onLine(buf);
}

async function readAll(stream: ReadableStream<Uint8Array>): Promise<string> {
	const decoder = new TextDecoder();
	const reader = stream.getReader();
	let out = "";
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		out += decoder.decode(value, { stream: true });
	}
	return out + decoder.decode();
}

const url = await getMainViewUrl();

const rpc = BrowserView.defineRPC<AppRPCType>({
	// Dry-runs on big datasets can take many seconds; disable the timeout entirely.
	maxRequestTime: Number.POSITIVE_INFINITY,
	handlers: {
		requests: {
			runDryRun: async ({ configPath, templateId }) => {
				const args = [
					"--config",
					configPath,
					"--dry-run",
					"--trace",
				];
				if (templateId && templateId.length > 0) {
					args.push("--template", templateId);
				}
				console.log("[bxp-cli] spawn:", BXP_CLI_PATH, args.join(" "));

				const proc = Bun.spawn([BXP_CLI_PATH, ...args], {
					stdout: "pipe",
					stderr: "pipe",
				});

				const sendTrace = (line: string) => {
					mainWindow.webview.rpc?.send.traceEvent({ line });
				};
				const sendStderr = (chunk: string) => {
					mainWindow.webview.rpc?.send.stderr({ chunk });
				};

				const stdoutTask = streamLines(proc.stdout, sendTrace);
				const stderrTask = readAll(proc.stderr);

				await stdoutTask;
				const stderrText = await stderrTask;
				const exitCode = await proc.exited;

				if (stderrText.length > 0) sendStderr(stderrText);
				return { exitCode, stderr: stderrText };
			},
			loadConfig: async ({ path }) => {
				const rawText = await Bun.file(path).text();
				const proc = Bun.spawn([BXP_FMT_PATH, "--config", path], {
					stdout: "pipe",
					stderr: "pipe",
				});
				const stderrText = await readAll(proc.stderr);
				await readAll(proc.stdout);
				const exitCode = await proc.exited;
				const validationError =
					exitCode === 0 ? null : stderrText.trim() || `bxp-fmt exit ${exitCode}`;
				return { rawText, validationError };
			},
			saveConfig: async ({ path, text }) => {
				const tmpPath = `${path}.bxp-tmp`;
				try {
					// Backup original before overwriting
					const exists = await access(path).then(() => true).catch(() => false);
					if (exists) {
						const now = new Date();
						const ts = [
							now.getFullYear(),
							String(now.getMonth() + 1).padStart(2, "0"),
							String(now.getDate()).padStart(2, "0"),
							String(now.getHours()).padStart(2, "0"),
							String(now.getMinutes()).padStart(2, "0"),
							String(now.getSeconds()).padStart(2, "0"),
						].join("");
						await copyFile(path, `${path}_${ts}`);
					}
					// Atomic write: temp file then rename
					await Bun.write(tmpPath, text);
					await rename(tmpPath, path);
					return { ok: true, error: null };
				} catch (e) {
					try {
						await unlink(tmpPath);
					} catch {
						// tmp file may not exist yet; ignore cleanup failure
					}
					return {
						ok: false,
						error: e instanceof Error ? e.message : String(e),
					};
				}
			},
			validateExpr: async ({ expr }) => {
				const proc = Bun.spawn([BXP_FMT_PATH, "--expr", expr], {
					stdout: "pipe",
					stderr: "pipe",
				});
				const stderrText = await readAll(proc.stderr);
				await readAll(proc.stdout);
				const exitCode = await proc.exited;
				if (exitCode === 0) return { ok: true, error: null };
				return {
					ok: false,
					error: stderrText.trim() || `bxp-fmt exit ${exitCode}`,
				};
			},
			openInEditor: async ({ path }) => {
				try {
					Bun.spawn(["xdg-open", path], { stdout: "ignore", stderr: "ignore" });
					return { ok: true };
				} catch {
					return { ok: false };
				}
			},
			openUrl: async ({ url }) => {
				try {
					Bun.spawn(["xdg-open", url], { stdout: "ignore", stderr: "ignore" });
					return { ok: true };
				} catch {
					return { ok: false };
				}
			},
			getStartupConfig: async () => {
				const candidate = resolve(process.cwd(), "bxp-cli.json");
				return { path: existsSync(candidate) ? candidate : null };
			},
			getDocs: async () => {
				try {
					const proc = Bun.spawn([BXP_FMT_PATH, "--docs"], {
						stdout: "pipe",
						stderr: "ignore",
					});
					const out = await readAll(proc.stdout);
					const exitCode = await proc.exited;
					if (exitCode !== 0) return null;
					return JSON.parse(out);
				} catch {
					return null;
				}
			},
			// FIXME(v1.0.0): zenity dialog doesn't match the app's dark theme.
			// Replace with a custom in-app path input modal.
			openFileDialog: async () => {
				try {
					const proc = Bun.spawn(
						["zenity", "--file-selection", "--title=Open config", "--file-filter=JSON files (*.json *.json5) | *.json *.json5"],
						{ stdout: "pipe", stderr: "ignore" },
					);
					const out = (await readAll(proc.stdout)).trim();
					await proc.exited;
					return { path: out.length > 0 ? out : null };
				} catch {
					return { path: null };
				}
			},
		},
		messages: {},
	},
});

const mainWindow = new BrowserWindow({
	title: "bxp-ui",
	url,
	rpc,
	frame: {
		width: 1200,
		height: 800,
		x: 100,
		y: 100,
	},
});

// Apply native window tweaks via FFI (Linux/GTK only; silently ignored on failure).
// At runtime import.meta.dir = Resources/app/bun/ inside the dev/packaged bundle.
try {
	const nativeWrapperPath = resolve(import.meta.dir, "../../../bin/libNativeWrapper.so");
	if (existsSync(nativeWrapperPath)) {
		const nativeLib = dlopen(nativeWrapperPath, {
			setWindowIcon: {
				args: [FFIType.ptr, FFIType.cstring],
				returns: FFIType.void,
			},
		});
		const iconPath = resolve(import.meta.dir, "../../appIcon.png"); // Resources/appIcon.png
		if (existsSync(iconPath)) {
			nativeLib.symbols.setWindowIcon(mainWindow.ptr, ptr(Buffer.from(iconPath + "\0", "utf8")));
		}
	}
} catch {
	// Native icon setup failed — not critical.
}


console.log("bxp-ui started");
