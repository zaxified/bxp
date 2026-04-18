import type { ElectrobunConfig } from "electrobun";

export default {
	app: {
		name: "bxp-ui",
		identifier: "sh.blackboard.bxp-ui",
		version: "0.1.0",
	},
	build: {
		// Vite builds to dist/; scripts/stage-bins.sh cross-compiles the Zig
		// sidecar binaries into build-bin/ before electrobun's build step.
		// Destinations are relative to Resources/app/ in the final bundle —
		// see findSiblingBin in src/bun/index.ts (path #2).
		copy: {
			"dist/index.html": "views/mainview/index.html",
			"dist/assets": "views/mainview/assets",
			"build-bin/bxp-cli": "bin/bxp-cli",
			"build-bin/bxp-fmt": "bin/bxp-fmt",
		},
		// Ignore Vite output and staged binaries in watch mode — HMR handles
		// webview rebuilds separately and binaries are only needed at package time.
		watchIgnore: ["dist/**", "build-bin/**"],
		mac: {
			bundleCEF: false,
		},
		linux: {
			bundleCEF: false,
			icon: "assets/appIcon.png",
		},
		win: {
			bundleCEF: false,
		},
	},
} satisfies ElectrobunConfig;
