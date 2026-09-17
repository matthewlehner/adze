# Issue 5 — No static-analysis tooling

## Problem

The project has no Dialyzer or Credo configured. The recent compile-warning cleanup only happened because the warnings were obvious enough to be caught by the compiler itself. Static analysis would help catch:

- Type/spec mismatches (e.g. the `err ->` clause whose input was already narrowed to `{:ok, _}`).
- Dead code before it reaches CI.
- Complexity/clean-code issues in the growing CLI and formatter modules.

## Severity

🟢 Low — quality-of-life / maintainability improvement, not a correctness bug.

## Location

- `mix.exs` — add dev/test tooling
- Optional: `.credo.exs` if you decide to configure Credo rules

## Proposed fix

1. Add Dialyzer as a dev/test-only dependency:

   ```elixir
   {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
   ```

2. Run an initial build of the PLT:

   ```bash
   mix dialyzer --plt
   ```

3. Run `mix dialyzer` and triage every warning:
   - Fix genuine errors (e.g. type specs that don't match impleme clarations).
   - Add `@dialyzer` ignore annotations only for unavoidable third-party noise.

4. (Optional but recommended) Add Credo:

   ```elixir
   {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
   ```

   Then configure `.credo.exs` to match the project's style and address any high-priority checks.

## Acceptance criteria

- [ ] `mix dialyzer` completes with no errors and no unexplained warnings.
- [ ] If Credo is added, `mix credo --strict` (or the chosen severity) passes.
- [ ] CI runs both `mix dialyzer` and `mix credo` (if Credo is added) on every PR.
- [ ] `mix test` and `mix compile --warnings-as-errors` still pass.
