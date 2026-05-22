defmodule Adze.Definition do
  @moduledoc """
  Logical-definition primitive.

  A definition is a `def` (or `defp` / `defmacro` / `defmacrop` /
  `defguard` / `defguardp` / `defdelegate`) bundled with its leading
  allowlisted attributes (`@doc`, `@spec`, `@typedoc`, `@impl`,
  `@deprecated`, `@since`) and any leading comments those nodes carry.

  Used by write ops (`mv`, `extract`, `topo`) — the unit of mechanical
  edit is always the whole group, never a bare `def`.

  ## Grouping rules

    * Group key is `{kind, name, arity}`. Multi-clause defs that share
      the same key and are AST-adjacent collapse into one definition.
    * Blank lines do not break adjacency — only intervening AST nodes do.
    * Allowlisted attributes directly preceding the def attach to it.
      `@moduledoc` is excluded (module-level).
    * `@type`, `@typep`, `@opaque`, `@callback`, and `@macrocallback` are
      *also* valid attachment targets for `@doc`/`@spec`/`@typedoc`/etc.
      Treat them as **consumers** — when one appears, it absorbs any
      pending allowlisted attrs and resets state. No definition is
      emitted for them (definitions are def-family only); they just
      prevent attrs intended for a type or callback from poisoning the
      next def.
    * A non-allowlisted attribute (e.g. `@some_const 5`, `@dialyzer ...`,
      `@job opts`) interleaved between an allowlisted attribute and the
      def is genuinely ambiguous and raises
      `{:error, {:ambiguous_attribute, info}}` — the caller decides
      whether to skip the attr or attach it.
    * Leading comments hang off the *next* AST node (Sourceror behavior)
      so the walk collects them from each attribute it pulls in.

  ## Ambiguous attribute error shape

      {:error,
       {:ambiguous_attribute,
        %{
          def: %{kind: :def, name: :foo, arity: 0, line: 12},
          attributes: [%{name: :spec, line: 10}, %{name: :doc, line: 9}],
          intervening: [%{name: :some_const, line: 11}]
        }}}

    * `def` — the def whose attachment is ambiguous.
    * `attributes` — the allowlisted attrs that were pending.
    * `intervening` — the non-allowlisted attrs that interrupted the
      run. Always at least one.

  ## Widening the allowlist

  Some Elixir libraries introduce attributes that semantically belong to
  the next def — Oban Pro's `@job`, the Decorator library's `@decorate`,
  occasionally `@dialyzer`. There are two ways to treat them as
  attachable:

  **Per call** — pass `include_attrs:` in opts:

      Adze.Definition.find(source, "foo/1", include_attrs: [:job, :decorate])

  **Project-wide** — set the application config in `config/config.exs`:

      config :adze, include_attrs: [:job, :decorate]

  This is the recommended path when consuming adze as a project dep
  (`mix adze ...`): set the allowlist once based on what your project
  uses, and every `Adze.Definition` call — including those made by
  future `mv` / `extract` / `topo` write ops — picks it up.

  Both sources are merged with the built-in allowlist (`@doc`, `@spec`,
  `@typedoc`, `@impl`, `@deprecated`, `@since`). Per-call `include_attrs`
  adds to the application config; it does not override.

  User-provided names take precedence over the built-in consumer list
  (`@type`, `@typep`, `@opaque`, `@callback`, `@macrocallback`) — if you
  pass `[:type]` (you probably shouldn't), `@type` will attach to a def
  instead of acting as a consumer.
  """

  @def_kinds [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]
  @private_kinds [:defp, :defmacrop, :defguardp]
  @attachable_attrs [:doc, :spec, :typedoc, :impl, :deprecated, :since]
  @consumer_attrs [:type, :typep, :opaque, :callback, :macrocallback]

  defstruct [:module, :name, :arity, :kind, :visibility, :range, :nodes, :parts]

  @type t :: %__MODULE__{
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          kind: atom(),
          visibility: :public | :private,
          range: Sourceror.Range.t() | nil,
          nodes: [Macro.t()],
          parts: %{
            leading_comments: [map()],
            attributes: [{atom(), Macro.t()}],
            clauses: [Macro.t()]
          }
        }

  @type definition_spec :: String.t() | {atom(), non_neg_integer()}
  @type opts :: [include_attrs: [atom()]]

  @spec list_file(Path.t(), opts()) :: {:ok, [t()]} | {:error, term()}
  def list_file(path, opts \\ []) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> list(source, opts)
      {:error, reason} -> {:error, {:file_read, reason}}
    end
  end

  @spec list(String.t(), opts()) :: {:ok, [t()]} | {:error, term()}
  def list(source, opts \\ []) when is_binary(source) do
    allowlist = effective_allowlist(opts)

    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        try do
          {:ok, walk_modules(ast, "", [], allowlist)}
        catch
          {:ambiguous_attribute, info} -> {:error, {:ambiguous_attribute, info}}
        end

      {:error, reason} ->
        {:error, {:parse, reason}}
    end
  end

  @spec find_file(Path.t(), definition_spec(), opts()) ::
          {:ok, t()} | {:error, :not_found} | {:error, term()}
  def find_file(path, spec, opts \\ []) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> find(source, spec, opts)
      {:error, reason} -> {:error, {:file_read, reason}}
    end
  end

  @spec find(String.t(), definition_spec(), opts()) ::
          {:ok, t()} | {:error, :not_found} | {:error, term()}
  def find(source, spec, opts \\ []) when is_binary(source) do
    with {:ok, key} <- parse_definition_spec(spec),
         {:ok, defs} <- list(source, opts) do
      case Enum.find(defs, fn d -> {d.name, d.arity} == key end) do
        nil -> {:error, :not_found}
        d -> {:ok, d}
      end
    end
  end

  defp effective_allowlist(opts) do
    app_level =
      :adze
      |> Application.get_env(:include_attrs, [])
      |> Enum.filter(&is_atom/1)

    per_call =
      opts
      |> Keyword.get(:include_attrs, [])
      |> Enum.filter(&is_atom/1)

    Enum.uniq(@attachable_attrs ++ app_level ++ per_call)
  end

  # --- module discovery ---------------------------------------------------

  defp walk_modules({:__block__, _, exprs}, prefix, acc, allowlist) do
    Enum.reduce(exprs, acc, fn node, a -> walk_modules(node, prefix, a, allowlist) end)
  end

  defp walk_modules({:defmodule, _meta, [alias_ast, [{_do, body}]]}, prefix, acc, allowlist) do
    name = qualify(prefix, alias_name(alias_ast))
    here = group_body(body_to_list(body), name, allowlist)
    walk_modules(body, name, acc ++ here, allowlist)
  end

  defp walk_modules(_other, _prefix, acc, _allowlist), do: acc

  defp body_to_list({:__block__, _, exprs}), do: exprs
  defp body_to_list(single), do: [single]

  defp qualify("", n), do: n
  defp qualify(prefix, n), do: prefix <> "." <> n

  defp alias_name({:__aliases__, _, parts}) when is_list(parts) do
    parts |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
  end

  defp alias_name(atom) when is_atom(atom), do: inspect(atom)
  defp alias_name(_), do: "?"

  # --- per-module grouping state machine ----------------------------------
  #
  # State tuple: {groups (reversed), pending_attrs, intervening, current}
  #
  #   - pending_attrs: allowlisted @attrs accumulating before a def
  #   - intervening: non-allowlisted @attrs seen while pending_attrs was
  #     non-empty. Non-empty at a def site → ambiguous attachment, raise.
  #   - current: the multi-clause group currently being extended (or nil).

  defp group_body(nodes, module_name, allowlist) do
    {groups, _attrs, _intervening, current} =
      Enum.reduce(nodes, {[], [], [], nil}, fn node, state ->
        step(node, state, allowlist)
      end)

    groups
    |> flush(current)
    |> Enum.reverse()
    |> Enum.map(&build_definition(&1, module_name))
  end

  defp step(node, {groups, attrs, intervening, current}, allowlist) do
    cond do
      attachable_attr?(node, allowlist) ->
        # any in-progress multi-clause def closes when an attr appears
        {flush(groups, current), attrs ++ [node], intervening, nil}

      consumer_attr?(node) ->
        # @type / @callback / etc. — legitimate target for any pending
        # allowlisted attrs. Reset state, emit nothing.
        {flush(groups, current), [], [], nil}

      other_attr?(node, allowlist) ->
        # @some_const / @job / @dialyzer / etc. — only "intervening" if
        # we have pending attrs that were aimed at a def. With no
        # pending attrs, it's just an orphan module-level attribute.
        new_intervening =
          if attrs == [], do: intervening, else: intervening ++ [attr_info(node)]

        {flush(groups, current), attrs, new_intervening, nil}

      def_node?(node) ->
        if intervening != [] do
          throw({:ambiguous_attribute, ambiguous_info(node, attrs, intervening)})
        end

        key = def_key(node)

        if current && current.key == key && attrs == [] do
          {groups, [], [], %{current | clauses: current.clauses ++ [node]}}
        else
          new_group = %{key: key, attrs: attrs, clauses: [node]}
          {flush(groups, current), [], [], new_group}
        end

      true ->
        # any other top-level node (nested defmodule, alias, …) acts as
        # a boundary: close the current def and drop pending state.
        {flush(groups, current), [], [], nil}
    end
  end

  defp flush(groups, nil), do: groups
  defp flush(groups, current), do: [current | groups]

  defp build_definition(%{key: {kind, name, arity}, attrs: attrs, clauses: clauses}, module_name) do
    nodes = attrs ++ clauses

    %__MODULE__{
      module: module_name,
      name: name,
      arity: arity,
      kind: kind,
      visibility: visibility(kind),
      range: group_range(nodes),
      nodes: nodes,
      parts: %{
        leading_comments: collect_leading_comments(nodes),
        attributes: Enum.map(attrs, fn {:@, _, [{n, _, _}]} = a -> {n, a} end),
        clauses: clauses
      }
    }
  end

  # --- classifiers --------------------------------------------------------

  defp attachable_attr?({:@, _, [{name, _, _}]}, allowlist) when is_atom(name),
    do: name in allowlist

  defp attachable_attr?(_, _), do: false

  defp consumer_attr?({:@, _, [{name, _, _}]}) when is_atom(name),
    do: name in @consumer_attrs

  defp consumer_attr?(_), do: false

  # other_attr? is the catch-all — must be checked after attachable_attr?
  # and consumer_attr? so they get first dibs.
  defp other_attr?({:@, _, [{name, _, _}]}, allowlist) when is_atom(name),
    do: name not in allowlist and name not in @consumer_attrs

  defp other_attr?(_, _), do: false

  defp attr_info({:@, m, [{name, _, _}]}),
    do: %{name: name, line: Keyword.get(m, :line)}

  defp def_node?({kind, _, args}) when kind in @def_kinds and is_list(args), do: true
  defp def_node?(_), do: false

  defp def_key({kind, _, [head | _]}) do
    {name, arity} = name_arity(head)
    {kind, name, arity}
  end

  defp name_arity({:when, _, [head | _]}), do: name_arity(head)

  defp name_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp name_arity({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)),
    do: {name, 0}

  defp visibility(kind) when kind in @private_kinds, do: :private
  defp visibility(_), do: :public

  # --- comments + range ---------------------------------------------------

  defp collect_leading_comments(nodes) do
    Enum.flat_map(nodes, fn node ->
      node |> elem(1) |> Keyword.get(:leading_comments, [])
    end)
  end

  defp group_range([]), do: nil

  defp group_range(nodes) do
    ranges =
      nodes
      |> Enum.map(&safe_range/1)
      |> Enum.reject(&is_nil/1)

    case ranges do
      [] ->
        nil

      _ ->
        first = List.first(ranges)
        last = List.last(ranges)
        {start_line, start_col} = extend_for_comments(first, nodes)

        %Sourceror.Range{
          start: [line: start_line, column: start_col],
          end: last.end
        }
    end
  end

  defp safe_range(node) do
    Sourceror.get_range(node)
  rescue
    _ -> nil
  end

  # Comments hang off the next node, so the earliest comment line across
  # the group becomes the group's effective top.
  defp extend_for_comments(first_range, nodes) do
    base_line = Keyword.fetch!(first_range.start, :line)
    base_col = Keyword.fetch!(first_range.start, :column)

    case collect_leading_comments(nodes) do
      [] ->
        {base_line, base_col}

      comments ->
        min_line = comments |> Enum.map(& &1.line) |> Enum.min()

        if min_line < base_line do
          {min_line, 1}
        else
          {base_line, base_col}
        end
    end
  end

  # --- error info + spec parsing ------------------------------------------

  defp ambiguous_info({kind, meta, [head | _]}, attrs, intervening) do
    {name, arity} = name_arity(head)

    %{
      def: %{kind: kind, name: name, arity: arity, line: Keyword.get(meta, :line)},
      attributes: Enum.map(attrs, &attr_info/1),
      intervening: intervening
    }
  end

  defp parse_definition_spec({name, arity}) when is_atom(name) and is_integer(arity),
    do: {:ok, {name, arity}}

  defp parse_definition_spec(spec) when is_binary(spec) do
    case String.split(spec, "/") do
      [name, arity_str] when name != "" ->
        case Integer.parse(arity_str) do
          {n, ""} when n >= 0 -> {:ok, {String.to_atom(name), n}}
          _ -> {:error, {:bad_definition_spec, spec}}
        end

      _ ->
        {:error, {:bad_definition_spec, spec}}
    end
  end
end
