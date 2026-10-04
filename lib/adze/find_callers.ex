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
    * **`__MODULE__`-relative references** — `alias __MODULE__.Inner` then
      `Inner.fun(...)`, fully-qualified `__MODULE__.Inner.fun(...)`
      (with or without an alias), and self-references
      `__MODULE__.fun(...)` / `&__MODULE__.fun/n`, resolved against the
      innermost enclosing `defmodule`.

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
        target: %{module: "MyApp.Foo", function: :bar, arity: 2 | [1, 2] | :any},
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

  alias Adze.{AliasScope, ProjectRewrite}

  @type target_spec ::
          String.t()
          | {module() | String.t(), atom()}
          | {module() | String.t(), atom(), non_neg_integer() | [non_neg_integer()] | :any}

  @type target :: %{
          module: String.t(),
          function: atom() | String.t(),
          arity: non_neg_integer() | [non_neg_integer()] | :any
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

  # The module may be an atom or a "Foo.Bar" string (so callers that
  # only hold a name needn't intern an atom just to have it inspected).
  defp parse_target({mod, fun, arity} = spec)
       when (is_atom(mod) or is_binary(mod)) and is_atom(fun) and
              (is_integer(arity) or arity == :any) do
    build_target(mod, fun, arity, spec)
  end

  # A list of arities, e.g. every arity a definition with default
  # arguments is callable at.
  defp parse_target({mod, fun, [_ | _] = arities} = spec)
       when (is_atom(mod) or is_binary(mod)) and is_atom(fun) do
    if Enum.all?(arities, &(is_integer(&1) and &1 >= 0)),
      do: build_target(mod, fun, Enum.sort(Enum.uniq(arities)), spec),
      else: {:error, {:bad_target, spec}}
  end

  defp parse_target({mod, fun} = spec) when (is_atom(mod) or is_binary(mod)) and is_atom(fun),
    do: build_target(mod, fun, :any, spec)

  defp parse_target(str) when is_binary(str) do
    case Regex.run(
           ~r/^([A-Z][A-Za-z0-9_.]*)\.([a-z_!?][A-Za-z0-9_!?]*)(?:\/(\d+(?:,\d+)*))?$/,
           str
         ) do
      [_, mod, fun, arity] ->
        {:ok,
         %{
           module: mod,
           function: Adze.Names.existing_atom_or_string(fun),
           arity: parse_arity_str(arity)
         }}

      [_, mod, fun] ->
        {:ok, %{module: mod, function: Adze.Names.existing_atom_or_string(fun), arity: :any}}

      _ ->
        {:error, {:bad_target, str}}
    end
  end

  defp parse_target(other), do: {:error, {:bad_target, other}}

  defp build_target(mod, fun, arity, spec) do
    case module_name(mod) do
      {:ok, name} -> {:ok, %{module: name, function: fun, arity: arity}}
      :error -> {:error, {:bad_target, spec}}
    end
  end

  defp module_name(mod) when is_atom(mod), do: {:ok, inspect(mod)}

  defp module_name(mod) when is_binary(mod),
    do: if(Adze.Names.valid_module_name?(mod), do: {:ok, mod}, else: :error)

  # "2" -> 2; "1,2" -> [1, 2]
  defp parse_arity_str(str) do
    case str
         |> String.split(",")
         |> Enum.map(&String.to_integer/1)
         |> Enum.uniq()
         |> Enum.sort() do
      [single] -> single
      many -> many
    end
  end

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
        lines = String.split(content, "\n")

        ast
        |> expand_pipes()
        |> walk_for_target(target, lines)

      _ ->
        []
    end
  end

  # --- alias resolution --------------------------------------------------

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

  # Walk aliases and refs together so each call sees only the aliases in
  # effect at its position. Aliases are lexically scoped: one declared
  # inside a `def`, a do-block (`if`, `for`, `test`, ...) or a `->`
  # clause (`fn`, `case`, ...) ends with that construct. A nested module
  # inherits its parent's aliases, but changes inside it must not leak
  # out. `defmodule Inner` nested in `Outer` adds the implicit alias
  # `Inner` → `Outer.Inner` to the enclosing scope (visible inside
  # `Inner` and after it in `Outer`).
  defp walk_for_target(ast, target, lines) do
    {_, %{refs: refs}} =
      Macro.traverse(
        ast,
        %{refs: [], scope: [], aliases: %{}, alias_stack: []},
        fn node, acc -> visit(node, enter_lexical_scope(node, acc), target, lines) end,
        fn node, acc -> {node, leave_lexical_scope(node, acc)} end
      )

    Enum.reverse(refs)
  end

  # `defmodule` pushes both a module scope and an alias scope; its
  # implicit alias goes into the table *below* the push so it survives
  # the module's end.
  defp enter_lexical_scope({:defmodule, _, [alias_ast, _]}, acc) do
    current = current_scope(acc.scope)
    name = Adze.Names.defmodule_name(alias_ast, current || "")

    aliases =
      case AliasScope.implicit_alias(alias_ast, current, head_bound?(alias_ast, acc.aliases)) do
        nil -> acc.aliases
        {short, full} -> Map.put(acc.aliases, short, full)
      end

    %{acc | scope: [name | acc.scope], aliases: aliases, alias_stack: [aliases | acc.alias_stack]}
  end

  defp enter_lexical_scope(node, acc) do
    if AliasScope.scope_node?(node),
      do: %{acc | alias_stack: [acc.aliases | acc.alias_stack]},
      else: acc
  end

  defp leave_lexical_scope({:defmodule, _, [_, _]}, acc) do
    %{
      acc
      | scope: tl(acc.scope),
        aliases: hd(acc.alias_stack),
        alias_stack: tl(acc.alias_stack)
    }
  end

  defp leave_lexical_scope(node, acc) do
    if AliasScope.scope_node?(node),
      do: %{acc | aliases: hd(acc.alias_stack), alias_stack: tl(acc.alias_stack)},
      else: acc
  end

  defp head_bound?({:__aliases__, _, [first | _]}, aliases) when is_atom(first),
    do: Map.has_key?(aliases, Atom.to_string(first))

  defp head_bound?(_alias_ast, _aliases), do: false

  defp visit({:alias, _, args} = node, acc, _target, _lines) do
    aliases =
      args
      |> AliasScope.alias_bindings(current_scope(acc.scope))
      |> Enum.reduce(acc.aliases, &Map.put(&2, &1.name, &1.module))

    {node, %{acc | aliases: aliases}}
  end

  # &Mod.fun/arity (qualified capture)
  defp visit(
         {:&, _, [{:/, _, [{{:., _, [mod_ast, fun]}, _, _ctx}, arity_ast]}]} = node,
         acc,
         target,
         lines
       )
       when is_atom(fun) do
    arity = unwrap_int(arity_ast)

    acc =
      if match_call(mod_parts(mod_ast), fun, arity, acc.aliases, target, acc.scope),
        do: push_ref(acc, node, :capture, arity, lines),
        else: acc

    # Replace the capture with a leaf so the walk doesn't descend into
    # its inner `Mod.fun` node and report it again as a zero-arity call.
    {:ok, acc}
  end

  # Direct qualified call: Mod.fun(args)
  defp visit({{:., _, [mod_ast, fun]}, _, args} = node, acc, target, lines)
       when is_atom(fun) and is_list(args) do
    arity = length(args)

    if match_call(mod_parts(mod_ast), fun, arity, acc.aliases, target, acc.scope),
      do: {node, push_ref(acc, node, :call, arity, lines)},
      else: {node, acc}
  end

  defp visit(node, acc, _target, _lines), do: {node, acc}

  defp push_ref(acc, node, kind, arity, lines) do
    ref =
      node
      |> build_ref(kind, arity, lines)
      |> Map.put(:in_module, current_scope(acc.scope))

    %{acc | refs: [ref | acc.refs]}
  end

  defp current_scope([]), do: nil
  defp current_scope([top | _]), do: top

  defp arity_matches?(:any, _), do: true
  defp arity_matches?(wanted, arity) when is_list(wanted), do: arity in wanted
  defp arity_matches?(wanted, arity), do: arity == wanted

  # The module side of a qualified call as alias parts: `Foo.Bar` (and
  # `__MODULE__.Inner`) arrive as `__aliases__`; a bare `__MODULE__` is
  # its own node, treated as the one-part alias `[__MODULE__]`. Anything
  # else (a variable, an atom, an expression) isn't statically a module
  # reference we resolve.
  defp mod_parts({:__aliases__, _, parts}), do: parts
  defp mod_parts({:__MODULE__, _, ctx} = node) when is_atom(ctx), do: [node]
  defp mod_parts(_), do: nil

  defp match_call(nil, _fun, _arity, _aliases, _target, _scope), do: false

  defp match_call(parts, fun, arity, aliases, target, scope) do
    case resolve_module(parts, aliases, scope) do
      nil ->
        false

      resolved ->
        resolved == target.module and
          Adze.Names.name_matches?(target.function, fun) and
          arity_matches?(target.arity, arity)
    end
  end

  # A leading `{:__MODULE__, _, ctx}` part is the innermost-enclosing
  # module (from `scope`), and it's absolute: `__MODULE__.Inner` is
  # `Current.Inner` even if an alias shadows `Current`'s first segment,
  # so it skips alias lookup. Built as a string, not atoms — `current`
  # may be a label like `:erl_mod`, which then just never matches a
  # `Foo.Bar` target. Any other non-atom part (an expression that
  # evaluates to a module) can't be resolved statically: `nil`.
  defp resolve_module([{:__MODULE__, _, ctx} | rest], _aliases, scope) when is_atom(ctx) do
    case scope do
      [current | _] when rest == [] -> current
      [current | _] -> if Enum.all?(rest, &is_atom/1), do: current <> "." <> join_parts(rest)
      [] -> nil
    end
  end

  defp resolve_module(parts, aliases, _scope), do: resolve_parts(parts, aliases)

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
