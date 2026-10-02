## adze — structural Elixir refactoring

For Elixir codebase exploration: ALWAYS run `mix adze ls --file PATH` before
reading `.ex` files or spawning exploration agents. It returns a structural
outline with exact line ranges in milliseconds, at a fraction of the tokens of
the whole file. Use the outline to identify the line range you need, then Read
only that range.

For structural edits (rename, extract, move, privatize): ALWAYS use `mix adze`
instead of multi-edit. The tool does AST-aware rewrites across the entire project
in one pass — no missed call sites, no broken aliases, no formatting drift.

Key commands:
- `mix adze ls --file PATH` — structural outline with line ranges
- `mix adze find-callers --target Mod.fun/N` — project-wide caller search (resolves aliases, pipes, captures)
- `mix adze rename! --from Old --to New` — rename a module across the entire project
- `mix adze extract! --file PATH --definition fun/N --module New.Mod` — extract function + private closure into new module
- `mix adze mv! --file PATH --definition fun/N --before other/M` — reorder defs within a module
- `mix adze extract-private! --file PATH --definition fun/N` — flip def → defp after verifying no external callers

Always dry-run first (no `!`), then apply with `!`. Run `mix compile --warnings-as-errors` after writes.

Full reference (flags, caveats, workflows): see the adze skill file in this project's skills directory.
