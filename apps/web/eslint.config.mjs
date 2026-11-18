import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";
import tailwind from "eslint-plugin-better-tailwindcss";

// Layer boundaries from ARCHITECTURE.md: ui (app, components) → server → db.
// Imports may only point down the list.
const layer = (files, group, message) => ({
  files,
  rules: { "no-restricted-imports": ["error", { patterns: [{ group, message }] }] },
});

const useTheClient = "Call outboundFetch in src/outbound.ts, which sets a time limit.";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  layer(
    ["src/app/**", "src/components/**"],
    ["@/db", "@/db/**", "**/db", "**/db/**"],
    "UI must not touch the database layer. Call a service in src/server.",
  ),
  layer(
    ["src/server/**"],
    ["@/app/**", "@/components/**", "**/app/**", "**/components/**"],
    "Services must not import UI code.",
  ),
  layer(
    ["src/db/**"],
    ["@/app/**", "@/components/**", "@/server/**", "**/app/**", "**/components/**", "**/server/**"],
    "The database layer must not import services or UI code.",
  ),
  // DESIGN.md as a failing check. The theme in src/app/globals.css defines the only colours and
  // sizes that exist, so a class outside it (bg-blue-500) is an unknown class, and a one-off
  // value (w-[437px], text-[#333]) is refused outright.
  {
    files: ["src/**/*.{ts,tsx}"],
    plugins: { "better-tailwindcss": tailwind },
    settings: { "better-tailwindcss": { entryPoint: "src/app/globals.css" } },
    rules: {
      "better-tailwindcss/no-unknown-classes": "error",
      "better-tailwindcss/no-conflicting-classes": "error",
      "better-tailwindcss/no-restricted-classes": [
        "error",
        {
          restrict: [
            {
              pattern: "\\[([^\\[\\]]*?)\\](?!:)",
              message: "No one-off values. Use the scale and the tokens in DESIGN.md.",
            },
          ],
        },
      ],
    },
  },
  // shadcn's components are written by its CLI and use one-off values by design. Leave them as generated.
  {
    files: ["src/components/ui/**"],
    rules: { "better-tailwindcss/no-restricted-classes": "off" },
  },
  // ARCHITECTURE.md, "Outside services": only the client may call fetch, so no request to an
  // outside service can be made without its time limit.
  {
    files: ["src/**/*.{ts,tsx}"],
    ignores: ["src/outbound.ts"],
    rules: {
      "no-restricted-globals": ["error", { name: "fetch", message: useTheClient }],
      "no-restricted-properties": [
        "error",
        ...["globalThis", "window", "self"].map((object) => ({ object, property: "fetch", message: useTheClient })),
      ],
    },
  },
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    "test-results/**",
    "playwright-report/**",
  ]),
]);

export default eslintConfig;
