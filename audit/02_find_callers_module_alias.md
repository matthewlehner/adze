# Issue 2 — `find-callers` cannot resolve `__MODULE__`-based aliases

## Problem

`Adze.FindCallers.build_alias_table/2` skips any alias whose `__aliases__` parts contain non-atom AST nodes. `alias __MODULE__.Inner` parses as:

```elixir
{:alias, _, [{:__aliases__, _, [{:__MODULE__, _, nil}, :Inner]}]}
```

The first part is a tuple, not an atom, so the alias is dropped. Any subsequent `Inner.fun(...)` calls in that file cannot be resolved and are not reported as callers.

This is a common idiom for nested modules and protocol/behaviour implementations, so missing these callers can make `extract-private!` incorrectly believe a function has no external callers.

## Severity

🟡 Medium — caller graph can be incomplete; affects the safety of `extract-private!`.

## Location

- `lib/adze/find_callers.ex`
  - `build_alias_table/2` (`register_alias/2` clauses)
  - `resolve_parts/2` already returns `nil` for non-atom parts, so any resolved `Inner` reference is abandoned.

## Reproduction scenario

```elixir
files = %{
  "lib/x.ex" => """
  defmodule X do
    defmodule Inner do
      def thing(x), do: x
    end

    alias __MODULE__.Inner
    def go(x), do: Inner.thing(x)
  end
  """
}

{:ok, result} = Adze.FindCallers.find_callers("X.Inner.thing/1", files: files)
# result.total == 0, but it should be 1
```

The same pattern applies to captures: `&__MODULE__.Inner.thing/1`.

## Proposed fix

1. Maintain the current `defmodule` scope stack during `build_alias_table` (the main walk already tracks scope in `walk_for_target`, so reuse that information).
2. When encountering `alias __MODULE__.Inner`, synthesize an entry `Inner -> X.Inner` (where `X` is the enclosing module).
3. For fully-qualified references that start with `__MODULE__` (`__MODULE__.Inner.thing(...)`), resolve using the same scope.
4. Keep the existing guard that silently skips aliases we cannot resolve statically.

## Acceptance criteria

- [ ] `find_callers("X.Inner.thing/1", files: files)` finds the `Inner.thing(x)` call through `alias __MODULE__.Inner`.
- [ ] Add a test for the capture variant `&__MODULE__.Inner.thing/1`.
- [ ] Add a test for a module with a qualified `__MODULE__.Inner.thing(x)` call without an alias.
- [ ] Ensure no regressions for the existing `find_callers` tests (non-atom parts must still not crash).
- [ ] `mix test` passes and `mix compile --warnings-as-errors` stays clean.
