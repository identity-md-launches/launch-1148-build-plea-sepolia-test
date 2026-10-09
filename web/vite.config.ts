import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The static export is written to the repository root `dist/` with relative
// asset URLs so it works under an IPFS gateway subpath or an ENS name.
export default defineConfig({
  base: "./",
  plugins: [react()],
  build: {
    outDir: "../dist",
    emptyOutDir: true,
    sourcemap: false,
    target: "es2022",
  },
});
