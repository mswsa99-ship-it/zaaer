import { useState } from "react";
import { Moon, Sun } from "lucide-react";
import { currentTheme, setTheme } from "../lib/themeBootstrap";

/** Day/night switch for the staff header. The icon names the mode you are in; the label says what a tap does. */
export function ThemeToggle({ className }: { className: string }) {
  const [theme, set] = useState(currentTheme);
  const night = theme === "dark";
  return (
    <button type="button" className={className} data-testid="theme-toggle" data-theme-now={theme}
      aria-label={night ? "التحويل إلى الوضع النهاري" : "التحويل إلى الوضع الليلي"}
      onClick={() => { const next = night ? "light" : "dark"; setTheme(next); set(next); }}>
      {night ? <Moon className="h-5 w-5" aria-hidden="true" /> : <Sun className="h-5 w-5" aria-hidden="true" />}
    </button>
  );
}
