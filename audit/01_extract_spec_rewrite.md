# Issue 1 — Extract rewrites local calls inside `@spec` bodies

## Problem

`Adze.Extract.rewrite_def_body/3` walks *every* AST node in a definition group — attributes *and* clauses — and rewrites bare local calls/captures/pipes into qualified remote calls when the name/arity matches a public closure function.

If a surviving definition in the source file has an `@spec` that mentions a local **type** whose name happens to be the same as the extracted public function, the type call is also rewritten. Types and functions live in different namespaces, so `Target.foo()` may refer to a type that does not exist in the target module, producing a compile error.

## Severity

🟡 Medium — only triggers when a local type shares a name with an extracted public function, but silently breaking a `@spec` is a bad failure mode.

## Location

- `lib/adze/extract.ex`
  - `rewrite_def_body/3`
  - `build_rewrite_ops/5` (passes attributes + clauses to `rewrite_def/3`)
  - `render_closure_def/6` / `render_def_ast/4` (target-side rendering)

## Reproduction scenario

```elixir
source = """
defmodule Source do
  @type target :: integer()

  @spec other(target()) :: target()
  def other(x), do: Target.target(x)

  def target(x), do: x * 2
end
"""
```

Extracting `target/1` into `Extracted.Target` would currently rewrite the `@spec other(target()) :: target()` line to `@spec other(Extracted.Target.target()) :: Extracted.Target.target()`, which is likely wrong because `Extracted.Target.target` may not be a type.

## Proposed fix

1. In `build_rewrite_ops/5` (source-side surviving callers), only rewrite call/capture/pipe forms that appear *inside clause bodies*, not inside attribute bodies.
2. In target-side rendering, type qualification is already handled by `Adze.Types.qualify/3`. The local-call qualifier (`try_rewrite_source_local` / `render_def_ast`) should skip attributes and only touch clauses.
3. If you do need to rewrite attribute contents for other reasons (e.g. `__MODULE__` in a `@doc` string), do it separately and deliberately.

The cleanest split: pass only `definition.parts.clauses` to the local-call rewriter; leave attributes for the type qualifier.

## Acceptance criteria

- [ ] Add a regression test in `test/extract_test.exs` where an extracted public function name collides with a local type name in a surviving `@spec`. The resulting source must still compile (or at least produce a sane spec).
- [ ] The test should assert that the type reference is **not** qualified as a remote function call.
- [ ] `mix test` still passes.
- [ ] `mix compile --warnings-as-errors` still passes.
