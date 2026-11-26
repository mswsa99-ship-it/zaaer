/** LOCAL TEST HARNESS ONLY (never part of the product build): dev server for tests/harness/dialog with MOCKED rows. */
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";
const root = path.resolve(__dirname, "../..");
export default defineConfig({ root, plugins: [react()], server: { port: 4190, strictPort: true }, resolve: { alias: { "@": path.resolve(root, "src") } } });
