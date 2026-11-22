import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";
import { plugin as shadcn } from "@shadcn/lint";
import tailwind from "eslint-plugin-better-tailwindcss";

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

// ARCHITECTURE.md, "Types are the contract": an exported function of a module takes and returns
// types that have a name. A type written inline in a signature is one a caller cannot name.
const inlineObjectType = {
  selector:
    ":matches(ExportNamedDeclaration > FunctionDeclaration, ExportNamedDeclaration > VariableDeclaration > VariableDeclarator > ArrowFunctionExpression) > :matches(.params, .returnType) TSTypeLiteral",
  message: "An exported function of a module takes and returns named types. Declare this object type in the module's types.ts.",
};

// A selector cannot tell a function imported from a module from one such as setTimeout, so this
// rule reads where the function's name was declared.
const namedContract = {
  rules: {
    "no-return-type-of-module": {
      meta: { type: "problem", schema: [], messages: { named: "Import the named type the module's function answers, not the ReturnType of the function." } },
      create: (context) => ({
        "TSTypeReference[typeName.name='ReturnType'] TSTypeQuery > Identifier.exprName"(node) {
          const declared = context.sourceCode.getScope(node).references.find((reference) => reference.identifier === node)?.resolved?.defs[0];
          if (declared?.type === "ImportBinding" && /^@\/domain\//.test(declared.parent.source.value)) context.report({ node, messageId: "named" });
        },
      }),
    },
  },
};

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // src/proxy.ts is a screen's gate, which Next.js requires loose in src.
  mayNotImport(
    ["src/app/**", "src/proxy.ts"],
    ["db"],
    "A screen does not touch the database. Call a use case of a module in src/domain.",
    // A module's state.ts is pure, and a client component runs it in the browser, where the index
    // would bring the database's code.
    { group: [...pastTheIndex.group, "!@/domain/*/state"], message: useTheIndex },
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
  {
    files: ["src/domain/**/*.ts"],
    ignores: ["src/domain/**/*.test.ts", "src/domain/*/index.ts"],
    rules: { "no-restricted-syntax": ["error", inlineObjectType] },
  },
  {
    files: ["src/**/*.{ts,tsx}"],
    plugins: { "named-contract": namedContract },
    rules: { "named-contract/no-return-type-of-module": "error" },
  },
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
        inlineObjectType,
      ],
    },
  },
  // ARCHITECTURE.md, "Structure": a component has a file of its own, so a reader finds it by its
  // name. shadcn ships several components in a file, and its files stay as generated.
  {
    files: ["src/**/*.tsx"],
    ignores: ["src/components/ui/**"],
    rules: { "react/no-multi-comp": "error" },
  },
  misplaced(
    ["src/**"],
    ["src/{app,components,domain,lib,db}/**", "src/proxy.ts"],
    "src holds five folders (app, components, domain, lib, db) and the files Next.js requires loose in it. Move this file into one of the five.",
  ),
  misplaced(["src/domain/*"], [], "A file of src/domain belongs to a module: move it to src/domain/<module>."),
  misplaced(["src/lib/*"], [], "Each helper in src/lib is a folder: move this file to src/lib/<name>/index.ts."),
  // DESIGN.md as a failing check. The theme in src/app/globals.css defines the only colours and
  // sizes that exist, and a screen composes shadcn's components without restyling them.
  {
    files: ["src/**/*.{ts,tsx}"],
    plugins: { shadcn, "better-tailwindcss": tailwind },
    settings: { "better-tailwindcss": { entryPoint: "src/app/globals.css" } },
    rules: {
      // Any class on a shadcn/ui component but its place and width, such as p-4 on a Button.
      "shadcn/no-restyle": [
        "error",
        {
          // Where a component sits and how wide it is belongs to the screen. Its colour, type,
          // spacing, shape, effects and motion are its own.
          allow: ["layout"],
          // DESIGN.md: a raised surface is white. shadcn ships the tooltip in the page's grey.
          contracts: [{ pattern: "^ChartTooltipContent$", allow: ["layout", "bg-card"] }],
        },
      ],
      // A colour outside the theme's tokens, such as bg-blue-500.
      "shadcn/no-raw-colors": "error",
      // A one-off value, such as w-[437px].
      "shadcn/no-arbitrary-values": "error",
      // An inline style. A value computed as the page runs is a custom property that a class
      // reads, such as w-(--share).
      "shadcn/no-inline-styles": "error",
      // A class Tailwind does not know, such as rounded-huge.
      "shadcn/no-unknown-classes": "error",
      // A class built from a variable, such as `m-${size}`, which Tailwind never generates.
      "shadcn/require-static-classes": "error",
      // Two classes that fight, such as p-2 p-4.
      "better-tailwindcss/no-conflicting-classes": "error",
    },
  },
  // shadcn's components are written by its CLI, which uses one-off values and inline styles and
  // styles one component inside another. Leave them as generated.
  {
    files: ["src/components/ui/**"],
    rules: { "shadcn/no-restyle": "off", "shadcn/no-arbitrary-values": "off", "shadcn/no-inline-styles": "off" },
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
  globalIgnores([
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    "test-results/**",
    "playwright-report/**",
  ]),
]);

export default eslintConfig;
