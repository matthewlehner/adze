defmodule Adze.Types do
  @moduledoc """
  Module-local typespec primitives.

  Two responsibilities:

    * `index/1` — build a `{name, arity} => :public | :private` map of the
      `@type` / `@typep` / `@opaque` declarations in a module's body, used
      to recognize local type references when rewriting extracted specs.

    * `qualify/3` — walk an `@spec` / `@callback` / `@macrocallback`
      attribute AST and rewrite every bare reference to a local type
      into a fully-qualified call against the source module. So
      `@spec foo() :: t()` inside `MyApp.Source` becomes
      `@spec foo() :: MyApp.Source.t()` when extracted.

  Built specifically for `Adze.Extract`: when a public def whose `@spec`
  references a module-local type gets pulled into a new module, the
  qualified form keeps the type defined in exactly one place (the
  original source) and the new module simply references it.

  ## What's rewritten

    * Bare `t/0` → `Source.t/0`.
    * `result(a, b)` → `Source.result(a, b)`, recursively walking `a` and
      `b` too.
    * `id()` inside `@spec fetch(id())` → `Source.id()`. The function
      name (`fetch`) is preserved because the rewriter is
      structurally aware of `@spec`/`@callback` shape.

  ## What's left alone

    * `String.t()` and any other already-qualified call.
    * Built-in types (`integer`, `term`, `pos_integer`, etc.) — they're
      not in the index so the qualification check misses cleanly.
    * `@spec` head name (function being specced).
    * Anything outside `@spec` / `@callback` / `@macrocallback` (e.g.
      `@doc`, `@typedoc`, function bodies — see `qualify/3` clauses).

  ## `@typep` references

  An extracted `@spec` cannot reference a `@typep` from another module —
  the type is module-private. We surface this by throwing
  `{:typep_referenced, %{type: {name, arity}, source: module}}`, which
  `Adze.Extract` catches and returns as `{:error, ...}`. The user's
  remedy: widen the `@typep` to `@type` in source first, then re-extract.
  """

  @type type_index :: %{{atom(), non_neg_integer()} => :public | :private}

  @doc """
  Build a type index from a list of top-level module body nodes.

  Walks the body for `@type` / `@typep` / `@opaque` declarations.
  Returns `%{}` if there are none.
  """
  @spec index([Macro.t()]) :: type_index()
  def index(body_nodes) when is_list(body_nodes) do
    body_nodes
    |> Enum.flat_map(&type_decl/1)
    |> Map.new()
  end

  defp type_decl({:@, _, [{kind, _, [{:"::", _, [head | _]} | _]}]})
       when kind in [:type, :typep, :opaque] do
    case name_arity(head) do
      {name, arity} -> [{{name, arity}, visibility(kind)}]
      nil -> []
    end
  end

  defp type_decl(_), do: []

  defp name_arity({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}

  defp name_arity({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)),
    do: {name, 0}

  defp name_arity(_), do: nil

  defp visibility(:typep), do: :private
  defp visibility(_), do: :public

  @doc """
  Does this typespec AST reference any local type in `type_index`?

  Cheap pre-check used by `Adze.Extract` to decide whether a closure
  definition needs the AST-rewrite path or can stay on the
  slice-from-source path.
  """
  @spec references_local?(Macro.t(), type_index()) :: boolean()
  def references_local?(_ast, type_index) when map_size(type_index) == 0, do: false

  def references_local?(ast, type_index) do
    try do
      Macro.prewalk(ast, fn
        # already-qualified — never a local ref
        {{:., _, [{:__aliases__, _, _}, _]}, _, _} = node ->
          node

        {name, _, args} = node when is_atom(name) and is_list(args) ->
          if Map.has_key?(type_index, {name, length(args)}), do: throw(:found), else: node

        {name, _, ctx} = node when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) ->
          if Map.has_key?(type_index, {name, 0}), do: throw(:found), else: node

        other ->
          other
      end)

      false
    catch
      :found -> true
    end
  end

  @doc """
  Qualify a typespec attribute against `source_module`.

  Rewrites `@spec` / `@callback` / `@macrocallback` ASTs so every local
  type reference is replaced with a fully-qualified call against
  `source_module`. Other attributes (`@doc`, `@typedoc`, etc.) pass
  through unchanged.

  May throw `{:typep_referenced, info}` if the typespec references a
  `@typep` from the source module — callers should catch and convert
  to an error.
  """
  @spec qualify(Macro.t(), type_index(), String.t()) :: Macro.t()
  def qualify({:@, m, [{kind, m2, body}]}, type_index, source_module)
      when kind in [:spec, :callback, :macrocallback] do
    {:@, m, [{kind, m2, qualify_spec_body(body, type_index, source_module)}]}
  end

  def qualify(other, _type_index, _source_module), do: other

  defp qualify_spec_body([node], type_index, source_module) do
    [qualify_spec_node(node, type_index, source_module)]
  end

  defp qualify_spec_body(other, _type_index, _source_module), do: other

  # `@spec foo(a) :: result(a) when a: integer` — the outer `when`
  # wraps the `::`. Walk the inner `::` and also walk the guards.
  defp qualify_spec_node({:when, m, [inner, guards]}, type_index, source_module) do
    {:when, m,
     [
       qualify_spec_node(inner, type_index, source_module),
       qualify_walk(guards, type_index, source_module)
     ]}
  end

  defp qualify_spec_node({:"::", m, [head, return]}, type_index, source_module) do
    {:"::", m,
     [
       qualify_spec_head(head, type_index, source_module),
       qualify_walk(return, type_index, source_module)
     ]}
  end

  defp qualify_spec_node(other, _type_index, _source_module), do: other

  # The `@spec` head is `{fname, m, args}` — fname is the function being
  # specced, never a type. Walk args; preserve fname.
  defp qualify_spec_head({fname, m, args}, type_index, source_module)
       when is_atom(fname) and is_list(args) do
    {fname, m, Enum.map(args, &qualify_walk(&1, type_index, source_module))}
  end

  defp qualify_spec_head(other, _type_index, _source_module), do: other

  defp qualify_walk(ast, type_index, source_module) do
    Macro.prewalk(ast, fn
      # already-qualified call — leave alone
      {{:., _, [{:__aliases__, _, _}, _]}, _, _} = node ->
        node

      # arity-N type call
      {name, meta, args} = node when is_atom(name) and is_list(args) ->
        maybe_qualify(node, {name, length(args)}, args, meta, name, type_index, source_module)

      # arity-0 bare reference (could also be a type variable; index miss
      # leaves it alone)
      {name, meta, ctx} = node when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) ->
        maybe_qualify(node, {name, 0}, [], meta, name, type_index, source_module)

      other ->
        other
    end)
  end

  defp maybe_qualify(node, key, args, _meta, name, type_index, source_module) do
    case Map.get(type_index, key) do
      :public ->
        qualified_call(source_module, name, args)

      :private ->
        throw({:typep_referenced, %{type: key, source: source_module}})

      nil ->
        node
    end
  end

  # Zero out positioning meta on the synthesized nodes so Sourceror.to_string
  # doesn't get confused by stale line/column info inherited from the
  # original bare-name node.
  defp qualified_call(source_module, name, args) do
    parts = source_module |> String.split(".") |> Enum.map(&String.to_atom/1)
    {{:., [], [{:__aliases__, [], parts}, name]}, [], args}
  end
end
