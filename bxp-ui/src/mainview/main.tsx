import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { Electroview } from "electrobun/view";
import "./index.css";
import App from "./App";
import { useTraceStore } from "./store";
import type { AppRPCType } from "../shared/types";

const rpc = Electroview.defineRPC<AppRPCType>({
	// Dry-run requests may take many seconds on large datasets — disable timeout.
	maxRequestTime: Number.POSITIVE_INFINITY,
	handlers: {
		requests: {},
		messages: {
			traceEvent: ({ line }: { line: string }) =>
				useTraceStore.getState().pushLine(line),
			stderr: ({ chunk }: { chunk: string }) =>
				useTraceStore.getState().pushStderr(chunk),
		},
	},
});

const electroview = new Electroview({ rpc });
if (electroview.rpc) {
	useTraceStore.getState().attachRpc(electroview.rpc as unknown as Parameters<
		ReturnType<typeof useTraceStore.getState>["attachRpc"]
	>[0]);
}

createRoot(document.getElementById("root")!).render(
	<StrictMode>
		<App />
	</StrictMode>,
);
