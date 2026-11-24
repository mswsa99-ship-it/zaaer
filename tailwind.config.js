/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      // U1 note 05 / U2: Arabic needs taller lines than Latin — 1.6 for running text (Tailwind's default is 1.33–1.5)
      fontSize: {
        xs: ["0.75rem", { lineHeight: "1.2rem" }],
        sm: ["0.875rem", { lineHeight: "1.4rem" }],
        base: ["1rem", { lineHeight: "1.6rem" }],
      },
      fontFamily: {
        sans: ['"IBM Plex Sans Arabic"', '"Noto Sans Arabic"', "system-ui", "sans-serif"],
        // RoomAI tokens (plan 3.2): the display and code faces of the approved system (3.7 self-hosts the files)
        display: ['"Readex Pro"', '"IBM Plex Sans Arabic"', "system-ui", "sans-serif"],
        mono: ['"IBM Plex Mono"', "ui-monospace", "monospace"],
      },
      colors: {
        brand: {
          50: "#eef6f9",
          100: "#d4e9ef",
          200: "#a8d3df",
          300: "#71b4c7",
          400: "#3f93a8",
          500: "#2b7a90",
          600: "#1f5f74",
          700: "#1a4d5e",
          800: "#173e4d",
          900: "#14333f",
        },
        ink: {
          50: "#f5f7fa",
          100: "#e9edf3",
          200: "#cdd6e4",
          300: "#a3b3cb",
          400: "#566a8c", // U2 (approved 30 Oct): was #6f83a3 (3.85:1); now 5.47:1 on white
          500: "#4a5e80",
          600: "#33476a",
          700: "#243456",
          800: "#18233d",
          900: "#0e1730",
        },
        accent: {
          500: "#2bb3a3",
          600: "#1f9384",
          700: "#167366", // U2: the accent button with white text (5.71:1)
        },
        // U2: the border of fields and check boxes (3.07:1 on white — ink-200 is decoration only)
        "border-control": "#8494b0",
        // RoomAI approved tokens (plan 3.2): the single token file is src/lib/designTokens.ts; these reference
        // its CSS variables (bg-rai-night, text-rai-ink-muted, border-rai-line-strong …) so a token edit
        // re-skins every consumer. Legacy scales above stay until the screens are rebuilt (phase 6).
        rai: {
          paper: "var(--paper)",
          surface: "var(--surface)",
          "surface-sunken": "var(--surface-sunken)",
          line: "var(--line)",
          "line-strong": "var(--line-strong)",
          ink: "var(--ink)",
          "ink-muted": "var(--ink-muted)",
          night: "var(--night)",
          "on-night": "var(--on-night)",
          spark: "var(--spark)",
          "spark-text": "var(--spark-text)",
          "spark-tint": "var(--spark-tint)",
          saffron: "var(--saffron)",
          "saffron-text": "var(--saffron-text)",
          "saffron-tint": "var(--saffron-tint)",
          sand: "var(--sand)",
          "sand-sheer": "var(--sand-sheer)",
          success: "var(--success)",
          "success-tint": "var(--success-tint)",
          warning: "var(--warning)",
          "warning-tint": "var(--warning-tint)",
          danger: "var(--danger)",
          "danger-tint": "var(--danger-tint)",
          sky: "var(--sky)",
          "sky-tint": "var(--sky-tint)",
          stone: "var(--stone)",
          "stone-tint": "var(--stone-tint)",
          focus: "var(--focus)",
        },
        success: {
          50: "#e8f5ee",
          500: "#2f9e5b",
          600: "#227a47",
        },
        warning: {
          50: "#fbf3e8",
          500: "#d98a1b",
          600: "#a86810",
          700: "#8a5409", // U2: warning text on warning-50 (5.69:1)
        },
        danger: {
          50: "#fbeceb",
          500: "#c0392b",
          600: "#962a1f",
        },
      },
    },
  },
  plugins: [],
};
