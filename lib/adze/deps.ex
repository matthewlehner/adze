defmodule Adze.Deps do
  @moduledoc """
  Intra-module call graph.

  For each `defmodule` in a file, list every callable (def, defp, defmacro,
  defmacrop, defguard, defguardp, defdelegate) with which sibling callables
  it invokes by name + arity.

  External calls (`Foo.bar/0`, `Kernel.+/2`) and variable refs are dropped:
  an edge is only emitted when the call site's `{name, arity}` matches a
  callable defined in the same module. Pipes are expanded before walking
  so `x |> foo()` is detected as `foo/2`, and `&foo/2` captures count as
  edges too.

  ## Default arguments

  A def with default args has one graph node — the canonical (highest)
  arity. `def foo(a, b \\\\ 1)` produces one `foo/2` node, not separate
  `foo/1` + `foo/2` nodes. Calls at either arity resolve to `foo/2` so
  fan-in queries stay accurate; the synthetic `foo/1` that Elixir
  auto-derives at compile time is not a separate implementation, so
  treating it as one would produce phantom self-loops on recursive
  default-arg defs.
  """

  @callable_kinds [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]
  @body_kinds [:def, :defp, :defmacro, :defmacrop]

  @type call :: {atom(), non_neg_integer()}
  @type def_entry :: %{
          name: atom(),
          arity: non_neg_integer(),
          kind: atom(),
          private: boolean(),
          range: %{start: pos_integer(), end: pos_integer()} | nil,
          calls: [call()]
        }

  @spec deps_file(Path.t()) :: {:ok, map()} | {:error, term()}
  def deps_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> deps(source, file: path)
      {:error, reason} -> {:error, {:file_read, reason}}
    end
  end

  @spec deps(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def deps(source, opts \\ []) when is_binary(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        {:ok,
         %{
           file: Keyword.get(opts, :file),
           modules: collect_modules(ast)
         }}

      {:error, reason} ->
        {:error, {:parse, reason}}
    end
  end

  # --- module discovery ---------------------------------------------------

  defp collect_modules(ast), do: ast |> walk_modules([], "") |> Enum.reverse()

  defp walk_modules({:__block__, _, exprs}, acc, prefix) do
    Enum.reduce(exprs, acc, &walk_modules(&1, &2, prefix))
  end

  defp walk_modules({:defmodule, _meta, [alias_ast, [{_do, body}]]} = node, acc, prefix) do
    name = qualify(prefix, alias_name(alias_ast))

    entry = %{
      name: name,
      range: range(node),
      defs: analyze_module(body)
    }

    walk_modules(body, [entry | acc], name)
  end

  defp walk_modules(_other, acc, _prefix), do: acc

  defp qualify("", name), do: name
  defp qualify(prefix, name), do: prefix <> "." <> name

  # --- per-module analysis -----------------------------------------------

  defp analyze_module(body) do
    clauses = collect_clauses(body)
    defined = build_defined(clauses)

    # Emit one graph node per real implementation — i.e. per
    # `head_arity`. Default-arg synthetic arities (`foo/1` from
    # `def foo(a, b \\ 1)`) are NOT separate nodes; they resolve via
    # `defined` to the canonical `foo/2`. This keeps the graph clean
    # and matches what Elixir actually compiles: one body, one
    # implementation; the lower arity is auto-derived at compile time.
    clauses
    |> Enum.group_by(fn c -> {c.name, c.head_arity} end)
    |> Enum.map(fn {{name, arity}, group} -> def_entry(name, arity, group, defined) end)
    |> Enum.sort_by(fn d -> {def_sort_key(d.range), d.name, d.arity} end)
  end

  # defined: %{{name, arity} => {name, canonical_arity}}
  #
  # Default-arg synthetic arities collapse to the canonical (highest)
  # arity. `def foo(a, b \\ 1)` registers `foo/1` and `foo/2` as
  # separate graph nodes (so users can query either), but a call at
  # either arity resolves to `foo/2` — the actual implementation. The
  # earlier fate-sharing model recorded edges to every synthetic arity
  # and produced phantom self-loops on recursive default-arg defs (a
  # body calling `foo(...)` would record edges to both `foo/1` and
  # `foo/2`, doubling the recursive self-edge). Collapsing keeps fan-in
  # queries intact (both nodes share outgoing edges via the shared
  # body) without duplicating the call-site edges.
  defp build_defined(clauses) do
    clauses
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn {name, group} ->
      # Walk each clause's (head_arity - defaults_count)..head_arity
      # range and record the *highest* head_arity that covers each
      # arity. If both `def foo(a)` (no defaults) and
      # `def foo(a, b \\ 1)` coexist (rare, Elixir warns), the
      # default-arg's higher head_arity wins for foo/1 — semantically
      # questionable but symmetrical with how Elixir dispatches.
      canonical_by_arity =
        Enum.reduce(group, %{}, fn %{head_arity: ha, defaults_count: dc}, acc ->
          Enum.reduce((ha - dc)..ha, acc, fn a, acc ->
            Map.update(acc, a, ha, &max(&1, ha))
          end)
        end)

      for {arity, canonical} <- canonical_by_arity,
          do: {{name, arity}, {name, canonical}}
    end)
    |> Map.new()
  end

  defp def_entry(name, arity, group, defined) do
    calls =
      group
      |> Enum.flat_map(&find_calls(&1.body, defined))
      |> Enum.uniq()
      |> Enum.sort()

    %{
      name: name,
      arity: arity,
      kind: pick_kind(group),
      private: Enum.any?(group, & &1.private),
      range: aggregate_range(group),
      calls: calls
    }
  end

  defp def_sort_key(nil), do: 0
  defp def_sort_key(%{start: s}), do: s

  defp collect_clauses({:__block__, _, exprs}), do: Enum.flat_map(exprs, &clause_node/1)
  defp collect_clauses(expr), do: clause_node(expr)

  defp clause_node({kind, _meta, args} = node) when kind in @callable_kinds and is_list(args) do
    case args do
      [head_or_when | rest] ->
        case head_signature(head_or_when) do
          :unknown ->
            []

          {name, head_arity, defaults_count} ->
            body = if kind in @body_kinds, do: extract_body(rest), else: nil

            [
              %{
                kind: kind,
                name: name,
                head_arity: head_arity,
                defaults_count: defaults_count,
                private: kind in [:defp, :defmacrop, :defguardp],
                range: range(node),
                body: body
              }
            ]
        end

      _ ->
        []
    end
  end

  defp clause_node(_), do: []

  defp head_signature({:when, _, [head, _guard]}), do: head_signature(head)

  defp head_signature({name, _, args}) when is_atom(name) and is_list(args) do
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    {name, length(args), defaults}
  end

  defp head_signature({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) do
    {name, 0, 0}
  end

  defp head_signature(_), do: :unknown

  defp extract_body([body_kw | _]) when is_list(body_kw) do
    Enum.find_value(body_kw, fn
      {{:__block__, _, [:do]}, body} -> body
      {:do, body} -> body
      _ -> nil
    end)
  end

  defp extract_body(_), do: nil

  defp pick_kind(clauses) do
    Enum.find_value(@callable_kinds, :def, fn k ->
      if Enum.any?(clauses, &(&1.kind == k)), do: k, else: nil
    end)
  end

  defp aggregate_range(clauses) do
    starts = for %{range: %{start: s}} <- clauses, do: s
    ends = for %{range: %{end: e}} <- clauses, do: e

    case {starts, ends} do
      {[], _} -> nil
      {_, []} -> nil
      {ss, es} -> %{start: Enum.min(ss), end: Enum.max(es)}
    end
  end

  # --- call detection ----------------------------------------------------

  defp find_calls(nil, _defined), do: []

  defp find_calls(body, defined) do
    body
    |> expand_pipes()
    |> walk_calls(defined)
  end

  defp expand_pipes(ast) do
    Macro.prewalk(ast, fn
      # x |> foo(a, b)  ->  foo(x, a, b)
      {:|>, _, [lhs, {name, meta, args}]} when is_atom(name) and is_list(args) ->
        {name, meta, [lhs | args]}

      # x |> foo  ->  foo(x)  (bare RHS — Elixir treats it as a 1-arity call)
      {:|>, _, [lhs, {name, meta, ctx}]} when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) ->
        {name, meta, [lhs]}

      # x |> Mod.foo(a)  ->  Mod.foo(x, a)
      {:|>, _, [lhs, {{:., _, _} = dot, meta, args}]} when is_list(args) ->
        {dot, meta, [lhs | args]}

      other ->
        other
    end)
  end

  defp walk_calls(ast, defined) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        # &name/arity (local function reference)
        {:&, _, [{:/, _, [{name, _, ctx}, arity_ast]}]} = node, acc
        when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) ->
          case unwrap_int(arity_ast) do
            nil -> {node, acc}
            arity -> {node, maybe_record({name, arity}, defined, acc)}
          end

        # Local call: name(args...)
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, maybe_record({name, length(args)}, defined, acc)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp maybe_record(pair, defined, acc) do
    case Map.get(defined, pair) do
      nil -> acc
      canonical -> [canonical | acc]
    end
  end

  defp unwrap_int({:__block__, _, [n]}) when is_integer(n), do: n
  defp unwrap_int(n) when is_integer(n), do: n
  defp unwrap_int(_), do: nil

  # --- helpers -----------------------------------------------------------

  defp alias_name({:__aliases__, _, parts}) when is_list(parts) do
    parts |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
  end

  defp alias_name(atom) when is_atom(atom), do: inspect(atom)
  defp alias_name(other), do: Macro.to_string(other)

  defp range(node) do
    case Sourceror.get_range(node) do
      %Sourceror.Range{start: start_kw, end: end_kw} ->
        %{start: Keyword.get(start_kw, :line), end: Keyword.get(end_kw, :line)}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
