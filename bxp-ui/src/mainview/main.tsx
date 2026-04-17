import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { Electroview } from "electrobun/view";
import "./index.css";
import App from "./App";
import { traceBus } from "./traceBus";
import type { AppRPCType } from "../shared/types";

const rpc = Electroview.defineRPC<AppRPCType>({
	handlers: {
		requests: {},
		messages: {
			traceEvent: ({ line }: { line: string }) => traceBus.pushLine(line),
			stderr: ({ chunk }: { chunk: string }) => traceBus.pushStderr(chunk),
		},
	},
});

const electroview = new Electroview({ rpc });
traceBus.attach(electroview.rpc);

createRoot(document.getElementById("root")!).render(
	<StrictMode>
		<App />
	</StrictMode>,
);
