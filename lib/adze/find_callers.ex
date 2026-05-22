defmodule Adze.FindCallers do
  @moduledoc """
  Find every project-wide reference to a `Module.fun[/arity]`.

  Read-only consumer of `Adze.ProjectRewrite`'s file enumeration — same
  source loading as `rename` / `extract!`, no mutation. Output is a
  per-file list of call sites, captures, and pipe references.

  ## Scope

    * **Qualified calls** — `Module.fun(args)`, including the
      pipe-expanded form `x |> Module.fun(args)` and the bare-pipe form
      `x |> Module.fun`.
    * **Captures** — `&Module.fun/arity`.
    * **Aliased references** — `alias Foo.Bar` then `Bar.fun(...)`, and
      `alias Foo, as: F` then `F.fun(...)`, and brace-form
      `alias Foo.{Bar, Baz}`.

  Not yet handled (intentional v1 limits):

    * **Unqualified calls via `import Module`** — bare `fun(args)` after
      `import` is not detected. Imports rarely cross file boundaries
      in modern Elixir code; if this bites, file-local `import` scoping
      can be added later.
    * **Dynamic refs** — `apply/3`, `Module.concat(...)`, runtime
      module composition.
    * **String-literal mentions** — comments, `@moduledoc` heredocs.

  ## Output shape

      %{
        target: %{module: "MyApp.Foo", function: :bar, arity: 2 | :any},
        total: 3,
        files: %{
          "lib/x.ex" => [
            %{line: 10, kind: :call,    arity: 2, snippet: "MyApp.Foo.bar(a, b)",
              in_module: "MyApp.Caller"},
            %{line: 15, kind: :capture, arity: 2, snippet: "&Foo.bar/2",
              in_module: "MyApp.Caller"}
          ]
        }
      }

  `in_module` is the innermost-enclosing `defmodule` name at the ref's
  position, or `nil` for top-level refs (scripts, .exs without
  defmodule).

  ## Usage

      iex> Adze.FindCallers.find_callers("MyApp.Foo.bar/2", mix_root: ".")
      {:ok, %{target: ..., files: %{...}, total: 3}}

      iex> Adze.FindCallers.find_callers({MyApp.Foo, :bar, :any},
      ...>   files: %{"lib/x.ex" => "..."})
      {:ok, %{...}}
  """

  alias Adze.ProjectRewrite

  @type target_spec ::
          String.t()
          | {module(), atom()}
          | {module(), atom(), non_neg_integer() | :any}

  @type target :: %{
          module: String.t(),
          function: atom(),
          arity: non_neg_integer() | :any
        }

  @type caller :: %{
          line: pos_integer(),
          kind: :call | :capture,
          arity: non_neg_integer(),
          snippet: String.t(),
          in_module: String.t() | nil
        }

  @type result :: %{
          target: target(),
          total: non_neg_integer(),
          files: %{Path.t() => [caller()]}
        }

  @spec find_callers(target_spec(), keyword()) :: {:ok, result()} | {:error, term()}
  def find_callers(target_spec, opts \\ []) do
    with {:ok, target} <- parse_target(target_spec),
         {:ok, rewrite} <- ProjectRewrite.new(opts) do
      files = collect_callers(rewrite, target)
      total = files |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
      {:ok, %{target: target, total: total, files: files}}
    end
  end

  # --- target parsing ----------------------------------------------------

  defp parse_target({mod, fun, arity})
       when is_atom(mod) and is_atom(fun) and (is_integer(arity) or arity == :any) do
    {:ok, %{module: inspect(mod), function: fun, arity: arity}}
  end

  defp parse_target({mod, fun}) when is_atom(mod) and is_atom(fun) do
    {:ok, %{module: inspect(mod), function: fun, arity: :any}}
  end

  defp parse_target(str) when is_binary(str) do
    case Regex.run(~r/^([A-Z][A-Za-z0-9_.]*)\.([a-z_!?][A-Za-z0-9_!?]*)(?:\/(\d+))?$/, str) do
      [_, mod, fun, arity] ->
        {:ok, %{module: mod, function: String.to_atom(fun), arity: String.to_integer(arity)}}

      [_, mod, fun] ->
        {:ok, %{module: mod, function: String.to_atom(fun), arity: :any}}

      _ ->
        {:error, {:bad_target, str}}
    end
  end

  defp parse_target(other), do: {:error, {:bad_target, other}}

  # --- file enumeration --------------------------------------------------

  defp collect_callers(rewrite, target) do
    rewrite.igniter.rewrite
    |> Rewrite.sources()
    |> Enum.flat_map(fn source ->
      path = Rewrite.Source.get(source, :path)
      content = Rewrite.Source.get(source, :content)

      if String.valid?(content) do
        case scan_source(content, target) do
          [] -> []
          callers -> [{path, callers}]
        end
      else
        []
      end
    end)
    |> Map.new()
  end

  defp scan_source(content, target) do
    case Sourceror.parse_string(content) do
      {:ok, ast} ->
        aliases = build_alias_table(ast)
        lines = String.split(content, "\n")

        ast
        |> expand_pipes()
        |> walk_for_target(aliases, target, lines)

      _ ->
        []
    end
  end

  # --- per-file alias resolution -----------------------------------------

  defp build_alias_table(ast) do
    {_, table} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, args} = node, acc -> {node, register_alias(acc, args)}
        node, acc -> {node, acc}
      end)

    table
  end

  # alias Foo.Bar (skipped when parts contain non-atom AST nodes —
  # e.g. `alias __MODULE__.Inner` — since we can't statically build a
  # stable lookup key for those).
  defp register_alias(table, [{:__aliases__, _, parts}])
       when is_list(parts) do
    if Enum.all?(parts, &is_atom/1),
      do: Map.put(table, last_str(parts), join_parts(parts)),
      else: table
  end

  # alias Foo.Bar, as: Baz   /   alias Foo.Bar, warn: false (no rebinding)
  defp register_alias(table, [{:__aliases__, _, parts}, kw])
       when is_list(parts) and is_list(kw) do
    cond do
      not Enum.all?(parts, &is_atom/1) ->
        table

      true ->
        full = join_parts(parts)

        case extract_as_atom(kw) do
          nil -> Map.put(table, last_str(parts), full)
          as_atom -> Map.put(table, Atom.to_string(as_atom), full)
        end
    end
  end

  # alias Foo.{A, B, C.D}
  defp register_alias(table, [{{:., _, [base, :{}]}, _, members}]) do
    base_parts =
      case base do
        {:__aliases__, _, parts} when is_list(parts) ->
          if Enum.all?(parts, &is_atom/1), do: parts, else: nil

        _ ->
          nil
      end

    case base_parts do
      nil ->
        table

      _ ->
        base_str = join_parts(base_parts)

        Enum.reduce(members, table, fn
          {:__aliases__, _, parts}, acc when is_list(parts) ->
            if Enum.all?(parts, &is_atom/1) do
              full = base_str <> "." <> join_parts(parts)
              Map.put(acc, last_str(parts), full)
            else
              acc
            end

          _, acc ->
            acc
        end)
    end
  end

  defp register_alias(table, _), do: table

  defp extract_as_atom(kw) do
    Enum.find_value(kw, fn
      {key, value} ->
        if unwrap_atom(key) == :as do
          case value do
            {:__aliases__, _, [a]} when is_atom(a) -> a
            _ -> nil
          end
        end

      _ ->
        nil
    end)
  end

  defp unwrap_atom({:__block__, _, [a]}) when is_atom(a), do: a
  defp unwrap_atom(a) when is_atom(a), do: a
  defp unwrap_atom(_), do: nil

  defp last_str(parts), do: parts |> List.last() |> Atom.to_string()
  defp join_parts(parts), do: parts |> Enum.map(&Atom.to_string/1) |> Enum.join(".")

  # --- pipe expansion (qualified-call variant only) ----------------------

  # We only care about qualified-call shapes here; bare-name pipes are
  # left alone (Adze.Deps handles those for intra-module analysis).
  defp expand_pipes(ast) do
    Macro.prewalk(ast, fn
      # x |> Mod.fun(a, b)  →  Mod.fun(x, a, b)
      {:|>, _, [lhs, {{:., dot_meta, [mod_ast, fun]}, meta, args}]}
      when is_atom(fun) and is_list(args) ->
        {{:., dot_meta, [mod_ast, fun]}, meta, [lhs | args]}

      # x |> Mod.fun  (bare, no parens — arity 1 after pipe)
      {:|>, _, [lhs, {{:., dot_meta, [mod_ast, fun]}, meta, ctx}]}
      when is_atom(fun) and (is_atom(ctx) or is_nil(ctx)) ->
        {{:., dot_meta, [mod_ast, fun]}, meta, [lhs]}

      other ->
        other
    end)
  end

  # --- main walk ---------------------------------------------------------

  # `Macro.traverse/4` (pre + post) so we can track the enclosing
  # `defmodule` scope as we descend, then pop it on the way back up.
  # Each ref gets the innermost-enclosing module name as `in_module`,
  # which downstream consumers (e.g. `extract-private`) use to decide
  # whether a same-file ref is internal or external. `nil` when the
  # ref sits at file top level (scripts, .exs without defmodule).
  defp walk_for_target(ast, aliases, target, lines) do
    {_, %{refs: refs}} =
      Macro.traverse(
        ast,
        %{refs: [], scope: []},
        fn
          {:defmodule, _, [alias_ast, _]} = node, acc ->
            name = qualify_scope(acc.scope, alias_name(alias_ast))
            {node, %{acc | scope: [name | acc.scope]}}

          # &Mod.fun/arity (qualified capture)
          {:&, _,
           [
             {:/, _,
              [
                {{:., _, [{:__aliases__, _, parts}, fun]}, _, _ctx},
                arity_ast
              ]}
           ]} = node,
          acc
          when is_atom(fun) ->
            arity = unwrap_int(arity_ast)

            if match_call(parts, fun, arity, aliases, target) do
              {node, push_ref(acc, node, :capture, arity, lines)}
            else
              {node, acc}
            end

          # Direct qualified call: Mod.fun(args)
          {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = node, acc
          when is_atom(fun) and is_list(args) ->
            arity = length(args)

            if match_call(parts, fun, arity, aliases, target) do
              {node, push_ref(acc, node, :call, arity, lines)}
            else
              {node, acc}
            end

          node, acc ->
            {node, acc}
        end,
        fn
          {:defmodule, _, _} = node, acc -> {node, %{acc | scope: tl(acc.scope)}}
          node, acc -> {node, acc}
        end
      )

    Enum.reverse(refs)
  end

  defp push_ref(acc, node, kind, arity, lines) do
    ref =
      node
      |> build_ref(kind, arity, lines)
      |> Map.put(:in_module, current_scope(acc.scope))

    %{acc | refs: [ref | acc.refs]}
  end

  defp current_scope([]), do: nil
  defp current_scope([top | _]), do: top

  defp qualify_scope([], name), do: name
  defp qualify_scope([parent | _], name), do: parent <> "." <> name

  defp alias_name({:__aliases__, _, parts}) when is_list(parts) do
    parts |> Enum.filter(&is_atom/1) |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
  end

  defp alias_name(atom) when is_atom(atom), do: inspect(atom)
  defp alias_name(_), do: "?"

  defp match_call(parts, fun, arity, aliases, target) do
    case resolve_parts(parts, aliases) do
      nil ->
        false

      resolved ->
        resolved == target.module and
          fun == target.function and
          (target.arity == :any or arity == target.arity)
    end
  end

  # `__aliases__` parts are *usually* a list of atoms, but Elixir allows
  # the first element to be an AST node like `{:__MODULE__, _, nil}` for
  # `__MODULE__.Inner` references, or any expression that returns a
  # module (rare but legal). We can't statically resolve those — return
  # `nil` so the caller treats this as "doesn't match the target."
  defp resolve_parts(parts, aliases) do
    if Enum.all?(parts, &is_atom/1) do
      [first | rest] = parts
      first_str = Atom.to_string(first)

      case Map.get(aliases, first_str) do
        nil ->
          join_parts(parts)

        full ->
          case rest do
            [] -> full
            _ -> full <> "." <> join_parts(rest)
          end
      end
    else
      nil
    end
  end

  defp build_ref(node, kind, arity, lines) do
    line = node_line(node)
    %{line: line, kind: kind, arity: arity, snippet: line_snippet(lines, line)}
  end

  defp node_line(node) do
    case node do
      {_, meta, _} when is_list(meta) -> Keyword.get(meta, :line, 0)
      _ -> 0
    end
  end

  defp line_snippet(_lines, 0), do: ""

  defp line_snippet(lines, line) do
    case Enum.at(lines, line - 1) do
      nil -> ""
      raw -> String.trim(raw)
    end
  end

  defp unwrap_int({:__block__, _, [n]}) when is_integer(n), do: n
  defp unwrap_int(n) when is_integer(n), do: n
  defp unwrap_int(_), do: 0
end
