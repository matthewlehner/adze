---
name: adze
description: Structural Elixir refactoring and outline-first reading via Mix tasks. Use for reading large Elixir files (ls/outline), renaming modules, extracting functions into new modules, reordering definitions, finding callers, and privatizing helpers.
---

# adze

Structural Elixir refactoring and outline-first reading. adze does the
mechanical work; you decide what to do; the compiler catches mistakes.
Run every command from the project root.

## When to reach for adze

| You're about to... | Use this instead |
| --- | --- |
| Read an Elixir file > 200 lines | `mix adze ls --file PATH`, then read only the line range you need |
| Multi-edit a `defmodule` rename across the project | `mix adze rename --from Old --to New` |
| Move a function + its private helpers into a new module by hand | `mix adze extract --file PATH --definition fun/N --module New.Module` |
| Reorder defs inside a module | `mix adze mv --file PATH --definition fun/N --before other/M` |
| Grep for callers of `Mod.fun` | `mix adze find-callers --target Mod.fun/N` |
| Turn a `def` into `defp` | `mix adze extract-private --file PATH --definition fun/N` |
| Check a module's `alias` / `import` / `use` | `mix adze aliases --file PATH` |

Otherwise use your normal read/edit/grep tools. Every op accepts
`--format json`; the default text output is meant for you to read.

## Read ops (never write)

- **`ls --file PATH`** (alias `outline`) — every definition with line
  ranges. Legend: `  foo/2` def, `p` defp, `m` defmacro, `g` defguard,
  `d` defdelegate, `[private]` for defmacrop/defguardp, `when …` if a
  clause has a guard, `(N clauses)` for multi-clause functions.
- **`deps --file PATH [--definition fun/N]`** — same-module call graph,
  caller → callees (pipes and captures included).
- **`ls-deps --file PATH --definition fun/N`** — transitive call tree
  from one def; `↺` marks revisits.
- **`ls-extract --file PATH --definition fun/N`** — the def plus the
  `defp`s only it uses, i.e. what `extract` would move. Only useful when
  choosing where to cut; `extract` computes this itself.
- **`aliases --file PATH`** — every `alias` / `import` / `require` /
  `use` per module.
- **`find-callers --target Mod.fun[/N]`** — project-wide qualified calls,
  pipes and `&Mod.fun/n` captures, resolving aliases per file. Omit the
  arity to match any; `/1,2` matches several. **Misses:** bare calls via
  `import`, `apply/3`, module names in strings.

## Write ops

They write straight to disk and print a summary: files touched with
+/- counts, plus anything you must act on. Every check runs before
anything is written, so a refusal leaves the tree untouched. The error
message says what to do next. Afterwards, always run
`mix compile --warnings-as-errors`. See `git diff` for the changes; undo
with git.

`--diff` also prints the full diffs. `--dry-run` prints them without
writing; use it only when you can't easily revert (uncommitted changes
in the affected files) or you just want to know whether an op would
work.

- **`mv --file PATH --definition fun/N --before other/M`** — moves the
  def with its clauses, leading comments and `@doc` / `@spec` / `@impl`
  to just before `--before`. Same module only.
- **`extract --file PATH --definition fun/N --module New.Mod`** — moves
  the def and its private closure to a new file (path from `--module`,
  or `--path`), and rewrites callers across the project. `alias`es are
  copied as needed; `use` / `import` / `require` are not. They're listed
  under "dropped directives" so you can add back what the compiler asks
  for. Refuses if the target file exists. Pass `--from-module` if the
  def exists in several modules in the file. Refuses on moves that
  wouldn't compile (macros/guards left behind or still called, files
  that `import` the source); the message says how to unblock. Not
  detected: imports injected by `use` at runtime
  (`import unquote(mod)`). Those show up as "undefined function" when
  you compile.
- **`rename --from Old.Mod --to New.Mod`** — `defmodule`, every
  directive, call sites, the test module, string mentions, and moves the
  file. If it refuses with surviving references, fix the real ones by
  hand or re-run with `--force` for false positives.
- **`extract-private --file PATH --definition fun/N`** — flips `def` →
  `defp` (`defmacro` → `defmacrop`, `defguard` → `defguardp`). Runs
  `find-callers` itself and refuses if anything outside the module calls
  it or it's a behaviour callback (`--force` overrides the "may be a
  callback" case). No need to check callers first. Shares
  `find-callers`' blind spots.

## Config

`config :adze, include_attrs: [:job, :decorate]` teaches adze about
custom attributes that attach to the next def (e.g. Oban's `@job`).
