import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";
import tailwind from "eslint-plugin-better-tailwindcss";

// ARCHITECTURE.md, "Structure": the app's code sits in five folders, and each may import only some
// of the others. A module of src/domain is a deep module: what is outside its folder uses its index.ts.
const useTheIndex =
  "Import a module through its index.ts (@/domain/<module>). What several modules or screens share with no product knowledge goes in src/lib.";
const pastTheIndex = { group: ["@/domain/*/**", "**/domain/*/**"], message: useTheIndex };
// From one module's folder, a file in the folder beside it. A file of the module's own is imported
// by its relative path (./key-cipher).
const besideTheModule = { regex: "^\\.\\./[^./][^/]*/.+", message: useTheIndex };

const folder = (name) => [`@/${name}`, `@/${name}/**`, `**/${name}`, `**/${name}/**`];

// A later block for the same rule replaces an earlier one, so each folder's block carries every
// pattern that holds for it.
const mayNotImport = (files, folders, message, ...more) => ({
  files,
  rules: { "no-restricted-imports": ["error", { patterns: [{ group: folders.flatMap(folder), message }, ...more] }] },
});

// Fails every file the block matches, for a file that is in no place the structure gives it.
const misplaced = (files, ignores, message) => ({
  files,
  ignores,
  rules: { "no-restricted-syntax": ["error", { selector: "Program", message }] },
});

const useTheClient = "Call outboundFetch in src/lib/outbound, which sets a time limit.";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // src/proxy.ts is a screen's gate, which Next.js requires loose in src.
  mayNotImport(
    ["src/app/**", "src/proxy.ts"],
    ["db"],
    "A screen does not touch the database. Call a use case of a module in src/domain.",
    pastTheIndex,
  ),
  mayNotImport(
    ["src/components/**"],
    ["app", "domain", "db"],
    "The design system holds no product knowledge: it imports src/lib alone. A product component goes in src/app.",
  ),
  mayNotImport(["src/lib/**"], ["app", "components", "domain", "db"], "A helper in src/lib imports nothing of the product's."),
  mayNotImport(["src/db/**"], ["app", "components", "domain"], "The database's folder imports src/lib alone."),
  mayNotImport(
    ["src/domain/**"],
    ["app", "components"],
    "A module of src/domain imports no screen and no component.",
    pastTheIndex,
    besideTheModule,
  ),
  // A unit test has no database, so a module's test replaces the repository of each module its use
  // cases call.
  mayNotImport(
    ["src/domain/**/*.test.ts"],
    ["app", "components"],
    "A module of src/domain imports no screen and no component.",
    { group: [...pastTheIndex.group, "!@/domain/*/repository"], message: useTheIndex },
    besideTheModule,
  ),
  // A module's index says what the module answers in types of its own. A type or function forwarded
  // from its repository or the database's folder would tie every caller to the table's shape.
  {
    files: ["src/domain/*/index.ts"],
    rules: {
      "no-restricted-syntax": [
        "error",
        {
          selector: ":matches(ExportNamedDeclaration, ExportAllDeclaration)[source.value=/^(@\\/db(\\/|$)|\\.\\/repository$)/]",
          message: "A module's index does not re-export from its repository or from src/db. Declare what a caller needs in the module.",
        },
      ],
    },
  },
  misplaced(
    ["src/**"],
    ["src/{app,components,domain,lib,db}/**", "src/proxy.ts"],
    "src holds five folders (app, components, domain, lib, db) and the files Next.js requires loose in it. Move this file into one of the five.",
  ),
  misplaced(["src/domain/*"], [], "A file of src/domain belongs to a module: move it to src/domain/<module>."),
  misplaced(["src/lib/*"], [], "Each helper in src/lib is a folder: move this file to src/lib/<name>/index.ts."),
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
    ignores: ["src/lib/outbound/index.ts"],
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
