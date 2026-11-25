/**
 * LOCAL TEST HARNESS ONLY (never part of the product build). Builds the demo UI into a separate directory with one extra
 * transform: the demo's fn_my_permissions also returns page_access taken from localStorage["__harness_page_access"], so a
 * browser test can render individual-mode accounts. Product sources are untouched; this config is not referenced by any npm script.
 */
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";

const root = path.resolve(__dirname, "../..");
export default defineConfig({
  root,
  plugins: [react(), {
    name: "harness-page-access",
    enforce: "pre",
    transform(code, id) {
      if (!id.endsWith("src/demo/permissions.ts")) return null;
      const needle = "sees_money: seesMoney() };";
      if (!code.includes(needle)) throw new Error("harness: fn_my_permissions anchor not found");
      return code.replace(needle, 'sees_money: seesMoney(), ...(globalThis.localStorage?.getItem("__harness_page_access") ? { page_access: JSON.parse(globalThis.localStorage.getItem("__harness_page_access")!) } : {}) };');
    },
  }],
  resolve: { alias: { "@": path.resolve(root, "src") } },
  build: { target: "es2022", outDir: "/tmp/dist-harness", emptyOutDir: true },
});
