---
name: pnpm
description: Use pnpm (or npm alias) to install and run Node.js packages, execute one-off commands via pnpm dlx, and manage global tools.
---

## What I do

- Install dependencies: `pnpm install`, `pnpm add <pkg>`, `pnpm add -g <pkg>`.
- Run scripts: `pnpm run <script>`, `pnpm <script>` (for known lifecycle scripts).
- Execute without install: `pnpm dlx <pkg>` (equivalent to npx).
- Inspect: `pnpm list`, `pnpm list -g`, `pnpm outdated`.

## When to use me

Use this skill when the agent needs to install a Node.js package, run a script defined in `package.json`, or execute a
one-off tool via `pnpm dlx`. Both `pnpm` and `npm` are available and point to the same binary.
