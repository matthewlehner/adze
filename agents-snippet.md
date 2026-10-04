## adze — structural Elixir refactoring

This project has adze, a Mix task that reads and refactors Elixir through its
AST. Prefer it to reading whole files, grepping for callers, or multi-editing:

- Before reading a large `.ex` file, run `mix adze ls --file PATH` and read only
  the line range you need.
- To find callers, run `mix adze find-callers --target Mod.fun/N`.
- To rename a module, extract a function, reorder definitions, or make a def
  private, use `mix adze rename` / `extract` / `mv` / `extract-private`. Run
  the dry-run form first, then the `!` form, then
  `mix compile --warnings-as-errors`.

Flags, caveats and workflows: the adze skill, at `.claude/skills/adze/SKILL.md`
or `.agents/skills/adze/SKILL.md`.
