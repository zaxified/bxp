import type { TraceEvent, UnknownEvent } from "./types";

export type ParseResult =
	| { kind: "event"; event: TraceEvent }
	| { kind: "unknown"; event: UnknownEvent }
	| { kind: "invalid"; raw: string; error: string };

export function parseLine(raw: string): ParseResult {
	const trimmed = raw.trim();
	if (trimmed.length === 0) {
		return { kind: "invalid", raw, error: "empty line" };
	}
	let parsed: unknown;
	try {
		parsed = JSON.parse(trimmed);
	} catch (e) {
		return {
			kind: "invalid",
			raw,
			error: e instanceof Error ? e.message : String(e),
		};
	}
	if (
		typeof parsed !== "object" ||
		parsed === null ||
		typeof (parsed as { t?: unknown }).t !== "string"
	) {
		return { kind: "invalid", raw, error: "missing t field" };
	}
	const obj = parsed as UnknownEvent;
	// Trust the shape — downstream code still narrows by t.
	return { kind: "event", event: obj as unknown as TraceEvent };
}
