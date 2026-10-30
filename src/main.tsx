import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter, HashRouter } from "react-router-dom";
import { isDemo } from "./lib/supabase";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AuthProvider } from "./lib/auth";
import { BranchProvider } from "./lib/branch";
import App from "./App";
import "./index.css";
import { startLabelLinker } from "./lib/a11y";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 30_000, refetchOnWindowFocus: false, retry: 1 },
  },
});

// The hosted demo is served from a static path, so it uses hash routing; production keeps clean URLs.
const Router = isDemo ? HashRouter : BrowserRouter;
// A build served below a sub-path (vite build --base /zaaer/, e.g. the GitHub Pages staging site) routes under
// that path; a root build ("/") needs no basename.
const basename = isDemo ? undefined : import.meta.env.BASE_URL.replace(/\/+$/, "") || undefined;

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <Router basename={basename}>
        <AuthProvider>
          {/* One branch scope for the whole app: BranchPicker, data hooks and the route guard share it (GAP01/GAP02). */}
          <BranchProvider>
            <App />
          </BranchProvider>
        </AuthProvider>
      </Router>
    </QueryClientProvider>
  </React.StrictMode>
);

startLabelLinker();
