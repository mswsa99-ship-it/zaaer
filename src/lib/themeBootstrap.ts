export function startTheme() {
  const media = window.matchMedia("(prefers-color-scheme: dark)");
  const apply = () => {
    let saved: string | null = null;
    try { saved = localStorage.getItem("roomai-theme"); } catch { /* optional preference */ }
    const theme = saved === "light" || saved === "dark" ? saved : media.matches ? "dark" : "light";
    document.documentElement.dataset.theme = theme;
    const color = getComputedStyle(document.documentElement).getPropertyValue("--paper").trim();
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", color);
  };
  apply(); media.addEventListener("change", apply);
  window.addEventListener("storage", e => { if (e.key === "roomai-theme") apply(); });
}
