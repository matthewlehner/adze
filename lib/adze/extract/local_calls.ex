defmodule Adze.Extract.LocalCalls do
  @moduledoc false
  # Qualifies bare local calls and captures (`foo(x)`, `x |> foo()`,
  # `&foo/1`) to a remote module, by effective arity.

  # Walk one AST node, qualifying bare local function references to
  # `Target.name(...)` where `Target` is the alias spelled by
  # `target_parts` (e.g. `[:MyTarget]` to qualify against an aliased
  # target module, or `[:MyApp, :Source]` to qualify against a full
  # source module path). Skips def heads — the head's `{name, _, args}`
  # shape would otherwise look like a call. Returns `{ast, changed?}`.
  # Used in two directions: target-bound rewriting of extracted bodies
  # (one-atom alias) and source-staying rewriting of survivor bodies
  # whose calls now have to cross modules (full-path).
  # Attributes (@spec, @doc, @type, etc.) live in a different namespace
  # than function calls -- a local type or literal value that happens to
  # share a name/arity with an extracted function must never be treated
  # as a call to it. Type qualification for @spec/@callback/@macrocallback
  # is handled separately by Adze.Types.qualify/3; every other attribute
  # is left untouched. This clause must come first so it takes precedence
  # over the map_size(keys) == 0 short-circuit and the generic clause below.
  def rewrite_def_body({:@, _, _} = node, _keys, _target_parts), do: {node, false}

  def rewrite_def_body(node, keys, _target_parts) when map_size(keys) == 0,
    do: {node, false}

  def rewrite_def_body({kind, m, [head, body]}, keys, target_parts)
      when kind in [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp] do
    {new_body, changed?} = rewrite_locals(body, keys, target_parts)
    {{kind, m, [head, new_body]}, changed?}
  end

  def rewrite_def_body(node, keys, target_parts) do
    rewrite_locals(node, keys, target_parts)
  end

  # A hand-rolled walk rather than `Macro.prewalk/3`: the pipe clauses
  # must control descent into their right-hand side. With prewalk, a
  # non-matching `x |> foo(2)` (effective arity 2) would be descended
  # into and `foo(2)` would then match the bare-call clause at arity 1,
  # qualifying it to a function that doesn't exist at that arity.
  defp rewrite_locals(ast, keys, target_parts) do
    walk_locals(ast, keys, target_parts)
  end

  # Capture: &name/arity → &Target.name/arity
  defp walk_locals(
         {:&, m, [{:/, sm, [{name, _nm, ctx}, {:__block__, _am, [arity]} = arity_node]}]} = node,
         keys,
         target_parts
       )
       when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) and is_integer(arity) do
    if MapSet.member?(keys, {name, arity}) do
      {{:&, m, [{:/, sm, [qualified(target_parts, name, [no_parens: true], []), arity_node]}]},
       true}
    else
      {node, false}
    end
  end

  # Pipe: `x |> name(...)` — at the AST level `name(...)` has its
  # written arity, but the pipe injects `x` as the first arg, so the
  # effective arity is len(args) + 1. Mirrors Adze.Deps's pipe
  # expansion. The rewritten rhs keeps its original args; the pipe
  # still feeds the extra arg. The rhs call itself is never re-examined
  # as a bare call — only its arguments are walked.
  defp walk_locals({:|>, m, [lhs, {name, rm, rhs_args}]}, keys, target_parts)
       when is_atom(name) and is_list(rhs_args) do
    {new_lhs, lhs_changed?} = walk_locals(lhs, keys, target_parts)
    {new_args, args_changed?} = walk_locals(rhs_args, keys, target_parts)

    if MapSet.member?(keys, {name, length(rhs_args) + 1}) do
      {{:|>, m, [new_lhs, qualified(target_parts, name, rm, new_args)]}, true}
    else
      {{:|>, m, [new_lhs, {name, rm, new_args}]}, lhs_changed? or args_changed?}
    end
  end

  # `x |> name` (no parens — effective arity 1)
  defp walk_locals({:|>, m, [lhs, {name, rm, ctx} = rhs]}, keys, target_parts)
       when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) do
    {new_lhs, lhs_changed?} = walk_locals(lhs, keys, target_parts)

    if MapSet.member?(keys, {name, 1}) do
      {{:|>, m, [new_lhs, qualified(target_parts, name, rm, [])]}, true}
    else
      {{:|>, m, [new_lhs, rhs]}, lhs_changed?}
    end
  end

  # Bare local call: name(args...) → Target.name(args...)
  defp walk_locals({name, meta, args}, keys, target_parts)
       when is_atom(name) and is_list(args) do
    {new_args, args_changed?} = walk_locals(args, keys, target_parts)

    if MapSet.member?(keys, {name, length(args)}) do
      {qualified(target_parts, name, meta, new_args), true}
    else
      {{name, meta, new_args}, args_changed?}
    end
  end

  # Any other call form (remote call, anonymous call, ...): walk both
  # the callee and the arguments.
  defp walk_locals({form, meta, args}, keys, target_parts) when is_list(args) do
    {new_form, form_changed?} = walk_locals(form, keys, target_parts)
    {new_args, args_changed?} = walk_locals(args, keys, target_parts)
    {{new_form, meta, new_args}, form_changed? or args_changed?}
  end

  defp walk_locals({a, b}, keys, target_parts) do
    {new_a, a_changed?} = walk_locals(a, keys, target_parts)
    {new_b, b_changed?} = walk_locals(b, keys, target_parts)
    {{new_a, new_b}, a_changed? or b_changed?}
  end

  defp walk_locals(list, keys, target_parts) when is_list(list) do
    Enum.map_reduce(list, false, fn item, acc ->
      {new_item, changed?} = walk_locals(item, keys, target_parts)
      {new_item, acc or changed?}
    end)
  end

  defp walk_locals(other, _keys, _target_parts), do: {other, false}

  defp qualified(target_parts, name, meta, args) do
    {{:., [], [{:__aliases__, [], target_parts}, name]}, meta, args}
  end
end
