# Issue 4 — Module disambiguation logic is duplicated

## Problem

When a source file contains multiple modules that each define a function with the same name/arity, the user can pass `--from-module` to pick which module to operate on. This disambiguation logic is implemented separately in:

- `Adze.Extract.resolve_source_module/3`
- `Adze.ExtractPrivate.find_definition/3` + `pick_match/4`

Both do approximately the same thing: collect matching defs, error if ambiguous and no `from_module` is given, validate that `from_module` is one of the candidates. Keeping two copies risks them diverging.

## Severity

🟢 Low — the logic is small and the tests pass, but duplication is a maintenance burden.

## Location

- `lib/adze/extract.ex` — `resolve_source_module/3`
- `lib/adze/extract_private.ex` — `find_definition/3`, `pick_match/4`
- `lib/adze/definition.ex` — `find/3` is the natural home for shared logic

## Proposed fix

Add an optional `:from_module` parameter to `Adze.Definition.find/3` (or a new `find_in_module/4`) that centralizes the candidate selection:

```elixir
@spec find(String.t(), definition_spec(), opts()) ::
        {:ok, t()} | {:error, :not_found} | {:error, term()}
```

where `opts()` now also accepts `:from_module`. The function should return:

- `{:ok, def}` when a single unambiguous match exists.
- `{:error, {:ambiguous_source_module, %{definition: ..., modules: [...]}}}` when there are multiple matches and no `from_module`.
- `{:error, {:from_module_mismatch, %{from: ..., candidates: [...]}}}` when `from_module` is provided but doesn't match.

Then refactor `Extract` and `ExtractPrivate` to use `Definition.find/3` for looking up the target definition and remove their duplicated helpers.

## Acceptance criteria

- [ ] `Adze.Definition.find/3` supports `:from_module` and the error shapes above.
- [ ] `Adze.Extract` uses `Definition.find/3` and no longer contains `resolve_source_module/3`.
- [ ] `Adze.ExtractPrivate` uses `Definition.find/3` and no longer contains `find_definition/3` / `pick_match/4`.
- [ ] All existing `Extract` and `ExtractPrivate` tests still pass with the same error messages.
- [ ] Add a test in `definition_test.exs` specifically for `:from_module` behavior.
- [ ] `mix test` passes and `mix compile --warnings-as-errors` stays clean.
