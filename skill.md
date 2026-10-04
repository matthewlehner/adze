---
name: adze
description: Structural Elixir refactoring and outline-first reading via Mix tasks. Use for reading large Elixir files (ls/outline), renaming modules, extracting functions into new modules, reordering definitions, finding callers, and privatizing helpers.
---

# adze

Structural Elixir refactoring + outline-first reading. Built on Sourceror
and Igniter. The tool does the mechanical work; you decide what to do;
the compiler catches mistakes.

## When to reach for adze

| You're about to... | Use this instead |
| --- | --- |
| Read an Elixir file > 200 lines | `mix adze ls --file PATH` first, then read only the line range you need |
| Multi-edit a `defmodule` rename across the project | `mix adze rename --from Old --to New` |
| Copy a function + its private helpers into a new module by hand | `mix adze extract --file ... --definition fun/N --module New.Module` |
| Reorder defs inside a module with multi-edit | `mix adze mv --file ... --definition fun/N --before other/M` |
| Grep for callers of `Mod.fun` across the project | `mix adze find-callers --target Mod.fun/N` |
| Convert a `def` to `defp` after eyeballing call sites | `mix adze extract-private --file ... --definition fun/N` |
| Eyeball a module's `alias`/`import`/`use` clauses | `mix adze aliases --file PATH` |

If none of these match, fall back to standard Read/Edit/Grep.

## Pre-flight

Run all commands from the project root (not via `--mix-root`).

```bash
mix adze ls --file lib/my_app/router.ex
```

## Read-only ops (safe, no-prompt)

### `ls` — file skeleton (alias: `outline`)

```bash
mix adze ls --file lib/my_app/router.ex
mix adze ls --file lib/my_app/router.ex --format json
```

Returns every top-level definition with line ranges. Legend:

- `defmodule Name   L1–540` — module
- `  foo/2   L42–58` — public def
- `p bar/1   L60` — private def (`defp`)
- `m macro_name/1   L75–90` — `defmacro` (suffix `[private]` for `defmacrop`)
- `g guard_name/1   L95` — `defguard` (suffix `[private]` for `defguardp`)
- `d delegated/2   L100` — `defdelegate`
- `@spec foo   L40` — type spec for `foo`
- `alias Module   L5` — directive

Then use your file-read tool on just the line range you need instead of
pulling the whole file.

### `deps` / `ls-deps` — intra-module call graph

```bash
mix adze deps --file lib/my_app/router.ex
mix adze deps --file lib/my_app/router.ex --definition dispatch/2
mix adze ls-deps --file lib/my_app/router.ex --definition dispatch/2
```

`deps` shows caller → callees for edges within the same module.
Pipes (`x |> foo()`) and captures (`&foo/2`) are handled.

`ls-deps` walks the transitive tree from one def (DFS). Revisits are
marked `↺`. Use it to see "what does this function actually touch."

### `ls-extract` — closure preview

```bash
mix adze ls-extract --file lib/my_app/router.ex --definition dispatch/2
```

The target def + every `defp` whose every same-module caller is in the
closure. Use it when you're deciding where to cut. `extract` computes
the same closure itself, so you don't need it before every extract.

### `aliases` — directive listing

```bash
mix adze aliases --file lib/my_app/router.ex
```

Per-module list of every `alias` / `import` / `require` / `use`.
Group-form `alias Foo.{A, B}` is expanded.

### `find-callers` — project-wide reference walker

```bash
mix adze find-callers --target MyApp.Foo.bar/2
mix adze find-callers --target MyApp.Foo.bar          # any arity
```

Walks every project source for qualified calls, pipe variants, and
`&Mod.fun/n` captures. Resolves per-file alias tables (including
`alias Foo, as: F` and brace-form). **Won't find:** unqualified calls
via `import`, dynamic `apply/3`, string-literal mentions.

## Write ops

Write ops write straight to disk and print a short summary: files
touched with +/- line counts, plus anything you must act on (dropped
directives, promotions, warnings). Then run
`mix compile --warnings-as-errors`. Every refusal check runs before
anything is written, so a refused op leaves the tree untouched. Use
`git diff` to see the changes and git to undo them.

`--dry-run` prints the full result (diffs, new file contents) without
writing. It's only worth it when you can't easily revert (uncommitted
changes in the files it would touch) or you're just asking "would this
work?". `--diff` writes and prints the full result.

### `mv` — reorder within a module

```bash
mix adze mv --file lib/my_app/router.ex --definition dispatch/2 --before init/1
```

Moves the whole logical definition group (leading comments + `@spec` /
`@doc` / `@impl` / `@deprecated` / `@since` + all clauses) to just
before `--before`. Same module only.

### `extract` — cut into a new module file

```bash
mix adze extract --file lib/my_app/router.ex --definition dispatch/2 --module MyApp.Dispatcher
```

Cuts the target def + its `defp` closure into `lib/my_app/dispatcher.ex`
(path derived from `--module`; pass `--path` to override). Rewrites
external callers across the project.

**Notes:**

1. `use` / `import` / `require` are **not** copied — they're listed
   under `dropped_directives` in the output. Add back what the new
   module needs (the compile step will tell you).
2. If the target file already exists, it errors. Pick a different name
   or delete the file first.
3. If the same def name exists in multiple `defmodule`s in the source
   file, pass `--from-module Foo.Mod` to disambiguate.

**Refusals** (extract stops instead of writing code that won't compile):

- The extracted code calls a public or private `defmacro` / `defguard`
  that stays in the source (`private_macro_referenced`). The target
  would need `require Source`.
- The target is a `defmacro` / `defguard` that the source or another
  file still calls (`moved_macro_referenced`). Callers would need
  `require Target`.
- Another file does `import Source` (or `use Source` when `Source` defines
  `__using__`) and could call a moved def (`imported_by`).
  Bare calls can't be retargeted. Switch them to qualified calls first.
  Literal `only:` / `except:` lists and `only: :macros | :functions`
  are honoured.

**Known gap:** an import whose module is only known at runtime
(`import unquote(mod)` inside a `__using__`, with `use Base, Source` at
the call site) is not detected. Extraction goes through and the bare call
fails to compile. After `extract`, run `mix compile --warnings-as-errors`
and look for "undefined function" at bare calls of the moved def.

### `rename` — module-wide rename

```bash
mix adze rename --from MyApp.Old --to MyApp.New
```

Updates `defmodule`, every `alias` / `use` / `import` / `require`, all
call sites, the test module, string-literal references, and moves the
file to its canonical location.

If `rename` refuses with surviving references, nothing was written.
Inspect each — fix real ones by hand, or pass `--force` for false
positives — then re-run.

### `extract-private` — flip `def` → `defp`

```bash
mix adze extract-private --file lib/my_app/router.ex --definition helper/2
```

Runs `find-callers` first. If zero external callers, flips `def` →
`defp` (or `defmacro` → `defmacrop`, `defguard` → `defguardp`).
Refuses on `defdelegate`. Inherits `find-callers`' blind spots.

## Workflow recipes

### Mapping an unfamiliar codebase

1. `mix adze ls --file <file>` — get the skeleton
2. Read only the line range for the function you care about
3. `mix adze find-callers --target Mod.fun/N` — see where it's used
4. `mix adze ls-deps --file ... --definition fun/N` — see what it touches

### Splitting a fat module

1. `mix adze extract --file ... --definition target/N --module New.Module`
   (not sure where to cut? `ls-extract` on a few candidates first)
2. `mix compile --warnings-as-errors` — add back any `dropped_directives` the new module needs

### Renaming a module

1. `mix adze rename --from Old --to New`
2. If it refuses with surviving references: fix real ones by hand or re-run with `--force` for false positives
3. `mix compile --warnings-as-errors`

### Privatizing an over-exposed helper

1. `mix adze extract-private --file ... --definition fun/N` — checks for
   external callers itself and refuses if there are any
2. `mix compile --warnings-as-errors`

## Important notes

- **Read ops never write** — only `mv` / `extract` / `rename` / `extract-private` touch disk, and not with `--dry-run`
- **Every op accepts `--format json`** — text (default) is optimized for LLMs reading inline
- **Runs as a Mix task, not a binary** — needs `Mix.Project.config()` loaded
- **Always compile after writes** — `mix compile --warnings-as-errors` catches what adze can't (imports, dynamic dispatch)
- **`find-callers` blind spots** — unqualified `import` calls, `apply/3`, string-literal module names
- **`:adze, :include_attrs` config** — teach adze about custom attachable attrs (e.g. `@job`, `@decorate`)

## Proactive usage

**Before reading any Elixir file over 200 lines, run `mix adze ls --file PATH` first.** Read only the line range you need.

**When the user asks to split or extract from a module,** run `mix adze extract`. Reach for `ls-extract` only when you're choosing between cut points.

**When you're about to multi-edit a rename across files,** use `mix adze rename` instead — it handles aliases, call sites, test modules, and file moves.

**When you see a public function that looks like it should be private,** run `mix adze extract-private` directly. It runs the caller search itself and refuses if anything outside the module calls it.

**After any adze write op, always run `mix compile --warnings-as-errors`.** The compiler is your safety net.
