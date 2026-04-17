import {
	JsonParser,
	JsonObjectNode,
	JsonArrayNode,
	JsonPrimitiveNode,
	type JsonValueNode,
} from "@croct/json5-parser";

// Walk `original` and `draft` in parallel, applying only the leaves that
// actually differ onto `node`. `node` is a CST that came from parsing the
// original source text, so untouched subtrees emit their original bytes
// (comments, whitespace, key order) verbatim on toString().
function applyDiff(
	node: JsonValueNode,
	original: unknown,
	draft: unknown,
): void {
	if (original === draft) return;

	if (isPlainObject(original) && isPlainObject(draft) && node instanceof JsonObjectNode) {
		for (const key of Object.keys(draft)) {
			const origChild = (original as Record<string, unknown>)[key];
			const draftChild = (draft as Record<string, unknown>)[key];
			if (origChild === draftChild) continue;
			if (!(key in original)) {
				node.set(key, draftChild as never);
				continue;
			}
			if (
				(isPlainObject(origChild) && isPlainObject(draftChild)) ||
				(Array.isArray(origChild) && Array.isArray(draftChild))
			) {
				applyDiff(node.get(key), origChild, draftChild);
			} else {
				node.set(key, draftChild as never);
			}
		}
		for (const key of Object.keys(original)) {
			if (!(key in draft)) node.delete(key);
		}
		return;
	}

	if (Array.isArray(original) && Array.isArray(draft) && node instanceof JsonArrayNode) {
		const minLen = Math.min(original.length, draft.length);
		for (let i = 0; i < minLen; i++) {
			const o = original[i];
			const d = draft[i];
			if (o === d) continue;
			if (
				(isPlainObject(o) && isPlainObject(d)) ||
				(Array.isArray(o) && Array.isArray(d))
			) {
				applyDiff(node.get(i), o, d);
			} else {
				node.set(i, d as never);
			}
		}
		for (let i = original.length - 1; i >= draft.length; i--) node.delete(i);
		for (let i = minLen; i < draft.length; i++) node.push(draft[i] as never);
		return;
	}

	// Structural mismatch (shape changed) or primitive mismatch — replace
	// the whole subtree. For a primitive-valued node we call .update().
	if (node instanceof JsonPrimitiveNode) {
		node.update(draft as never);
	} else {
		// Shouldn't reach here with leaf-only edits currently supported by
		// the tree UI, but handle gracefully for future structural edits.
		node.update(draft as never);
	}
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
	return v !== null && typeof v === "object" && !Array.isArray(v);
}

// Produce a JSON5 string for `draft` that preserves all comments,
// whitespace, and key order from `originalText` except where the user
// actually changed values. If the original can't be parsed, or the draft
// diverges structurally in a way the CST can't patch, fall back to a plain
// JSON5.stringify via `fallback`.
export function buildRoundtrippedText(
	originalText: string,
	original: unknown,
	draft: unknown,
	fallback: (v: unknown) => string,
): string {
	try {
		const root = JsonParser.parse(originalText, JsonObjectNode);
		applyDiff(root, original, draft);
		return root.toString();
	} catch {
		return fallback(draft);
	}
}
