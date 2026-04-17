type Listener = () => void;

type RunDryRunRequest = (args: {
	configPath: string;
	templateId?: string;
}) => Promise<{ exitCode: number; stderr: string }>;

type RpcLike = {
	request: { runDryRun: RunDryRunRequest };
};

class TraceBus {
	lines: string[] = [];
	stderr = "";
	private listeners = new Set<Listener>();
	private rpc: RpcLike | null = null;

	attach(rpc: unknown) {
		this.rpc = rpc as RpcLike;
	}

	pushLine(line: string) {
		this.lines.push(line);
		this.emit();
	}

	pushStderr(chunk: string) {
		this.stderr += chunk;
		this.emit();
	}

	reset() {
		this.lines = [];
		this.stderr = "";
		this.emit();
	}

	subscribe(l: Listener) {
		this.listeners.add(l);
		return () => this.listeners.delete(l);
	}

	private emit() {
		for (const l of this.listeners) l();
	}

	async runDryRun(configPath: string, templateId: string) {
		if (!this.rpc) throw new Error("RPC not attached");
		this.reset();
		return this.rpc.request.runDryRun({
			configPath,
			templateId: templateId.length > 0 ? templateId : undefined,
		});
	}
}

export const traceBus = new TraceBus();
