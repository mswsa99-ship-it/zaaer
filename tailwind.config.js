/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      fontFamily: {
        sans: ['"IBM Plex Sans Arabic"', '"Noto Sans Arabic"', "system-ui", "sans-serif"],
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
