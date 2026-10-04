defmodule Adze.ExtractPrivate do
  @moduledoc """
  Flip a public `def` (or `defmacro` / `defguard`) to its private form
  when `find-callers` reports zero external callers.

  Bookkeeping op — the analysis is "does anything outside this module
  call this function?" and the mechanical edit is a one-keyword swap
  per clause line. Dry-run by default; `extract_private!/2` writes.

  ## Scope

    * `def` → `defp`, `defmacro` → `defmacrop`, `defguard` → `defguardp`.
    * `defdelegate` has no private form — returns
      `{:error, :cannot_be_private}`.
    * Multi-clause defs flip every clause line.
    * Attached `@spec` / `@doc` / etc. are left in place. A `@spec` on
      a `defp` is allowed by the compiler.

  ## Behaviour callbacks and dynamic dispatch

  Callbacks are invoked dynamically (`GenServer` calls `mod.init/1`,
  Phoenix calls controller actions and LiveView callbacks via
  `apply/3`), so they never show up in `find-callers` and would look
  caller-free. Two guards cover this:

    * **Known callbacks are always refused** with
      `{:error, {:behaviour_callback, %{definition:, module:, reason:}}}`.
      `reason` is `{:impl, value}` when the definition carries
      `@impl true` / `@impl SomeBehaviour` (`@impl false` doesn't
      count), or `{:behaviour, "Mod"}` when a `@behaviour` / `use`d
      module that can be loaded lists the function among its callbacks.
    * **Possible callbacks are refused unless `force: true`** with
      `{:error, {:possible_callback, %{definition:, module:, uses:,
      behaviours:}}}`. That's any module with a `use` or `@behaviour`
      whose target can't be loaded as a behaviour to check its callback
      list — e.g. `use MyAppWeb, :controller`, which is how
      dynamically-dispatched modules like Phoenix controllers are set
      up. `use GenServer` alone doesn't trigger it: its callbacks are
      known, so other functions in the module are judged normally.

  ## Safety

  Any reference `Adze.FindCallers` reports blocks the flip. It only
  reports *qualified* references (`Mod.fun(...)`, `&Mod.fun/n`,
  `__MODULE__.fun(...)`), and a qualified call to a private function
  fails wherever it is — another file, a sibling module in the same
  file, or the target's own module (`S.b()` / `__MODULE__.b()` inside
  `S` is a remote call). In-module qualified self-calls are reported,
  not rewritten to local calls: they're often deliberate (hot code
  upgrade, mocking), so the user decides. Each ref carries
  `in_module` to tell the cases apart. Bare local calls (`b()`) are
  never reported and don't block.

  Definitions in modules `find-callers` can't search for (an atom like
  `defmodule :erlang_style`, or a dynamically built name) are refused
  with `{:error, {:unsupported_module, module}}`.

  Limitations inherited from `find-callers`: unqualified calls via
  `import` aren't detected, nor dynamic `apply/3`, nor string-literal
  mentions. If the codebase uses these against the target, this op
  will give a green light incorrectly. The compiler will catch the
  break on the next build, but the failure mode is loud — the user
  reads the error and reverts. Document it; don't hide it.

  ## Output shape

      {:ok, %{
        diff: "...",                 # unified-style line diff
        new_source: "...",
        module: "MyApp.Foo",
        name: :helper,
        arity: 2,
        from_kind: :def,
        to_kind: :defp
      }}

      {:error, {:external_callers, [
        %{path: "lib/x.ex", line: 10, kind: :call, arity: 2, snippet: "...",
          in_module: "MyApp.Bar"},
        ...
      ]}}

  ## Usage

      iex> Adze.ExtractPrivate.extract_private_file(
      ...>   "lib/foo.ex", definition: "helper/2")
      {:ok, %{diff: "...", from_kind: :def, to_kind: :defp}}

      Adze.ExtractPrivate.extract_private!("lib/foo.ex",
        definition: "helper/2")
      # → writes lib/foo.ex with `def helper` flipped to `defp helper`
  """

  alias Adze.{Definition, FindCallers}

  @type opts :: [
          definition: Definition.definition_spec(),
          mix_root: Path.t(),
          files: %{Path.t() => String.t()},
          include_attrs: [atom()],
          force: boolean()
        ]

  @type external_ref :: %{
          path: Path.t(),
          line: pos_integer(),
          kind: :call | :capture,
          arity: non_neg_integer(),
          snippet: String.t(),
          in_module: String.t() | nil
        }

  @type result :: %{
          diff: String.t(),
          new_source: String.t(),
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          from_kind: atom(),
          to_kind: atom()
        }

  @spec extract_private(String.t(), opts()) :: {:ok, result()} | {:error, term()}
  def extract_private(source, opts) when is_binary(source) and is_list(opts) do
    with {:ok, def_spec} <- fetch_opt(opts, :definition),
         {:ok, definition} <- find_definition(source, def_spec, opts),
         {:ok, to_kind} <- flip_kind(definition.kind),
         :ok <- ensure_public(definition),
         :ok <- ensure_searchable_module(definition),
         :ok <- ensure_not_callback(source, definition, opts),
         {:ok, fc_result} <- run_find_callers(definition, opts),
         {:ok, externals} <- classify_external(fc_result),
         :ok <- check_no_externals(externals) do
      new_source = flip_clauses(source, definition, to_kind)

      {:ok,
       %{
         diff: Adze.Diff.unified(source, new_source),
         new_source: new_source,
         module: definition.module,
         name: definition.name,
         arity: definition.arity,
         from_kind: definition.kind,
         to_kind: to_kind
       }}
    end
  end

  @spec extract_private_file(Path.t(), opts()) :: {:ok, result()} | {:error, term()}
  def extract_private_file(path, opts) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> extract_private(source, opts)
      {:error, reason} -> {:error, {:file_read, reason}}
    end
  end

  @spec extract_private!(Path.t(), opts()) :: {:ok, result()} | {:error, term()}
  def extract_private!(path, opts) when is_binary(path) do
    with {:ok, result} <- extract_private_file(path, opts) do
      case File.write(path, result.new_source) do
        :ok -> {:ok, result}
        {:error, reason} -> {:error, {:file_write, reason}}
      end
    end
  end

  # --- option / definition lookup ----------------------------------------

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_opt, key}}
    end
  end

  defp find_definition(source, spec, opts) do
    from_module = Keyword.get(opts, :from_module)

    with {:ok, parsed} <- Definition.parse_definition_spec(spec),
         {:ok, defs} <- Definition.list(source, Keyword.put(opts, :lenient, true)) do
      {name, arity} = Definition.resolve_key(parsed, defs)
      matches = Enum.filter(defs, &(&1.name == name and &1.arity == arity))

      with {:ok, picked} <- pick_match(matches, name, arity, from_module) do
        case picked.ambiguous do
          nil -> {:ok, picked}
          info -> {:error, {:ambiguous_attribute, info}}
        end
      end
    end
  end

  defp pick_match([], _name, _arity, _from), do: {:error, {:not_found, :definition}}
  defp pick_match([only], _, _, nil), do: {:ok, only}

  defp pick_match([only], _, _, from) do
    if only.module == from,
      do: {:ok, only},
      else: {:error, {:from_module_mismatch, %{from: from, candidates: [only.module]}}}
  end

  defp pick_match(many, name, arity, nil) do
    {:error,
     {:ambiguous_source_module,
      %{definition: {name, arity}, modules: Enum.map(many, & &1.module)}}}
  end

  defp pick_match(many, _, _, from) do
    case Enum.find(many, &(&1.module == from)) do
      nil ->
        {:error, {:from_module_mismatch, %{from: from, candidates: Enum.map(many, & &1.module)}}}

      picked ->
        {:ok, picked}
    end
  end

  defp ensure_public(%Definition{visibility: :public}), do: :ok

  defp ensure_public(%Definition{visibility: :private, kind: kind, name: n, arity: a}),
    do: {:error, {:already_private, %{kind: kind, definition: {n, a}}}}

  # `find-callers` can only search for a `Foo.Bar` module. Anything else
  # (`defmodule :erlang_style`, `defmodule Module.concat(...)`, recorded
  # as written) can't be searched, so refuse the flip rather than claim
  # there are no callers.
  defp ensure_searchable_module(%Definition{module: module}) do
    if Adze.Names.valid_module_name?(module),
      do: :ok,
      else: {:error, {:unsupported_module, module}}
  end

  # --- behaviour callbacks ------------------------------------------------

  defp ensure_not_callback(source, %Definition{} = d, opts) do
    {uses, behaviours} = module_behaviour_decls(source, d.module)
    keys = Enum.map(Definition.callable_arities(d), &{d.name, &1})
    info = %{definition: {d.name, d.arity}, module: d.module}

    # `use X` usually means X is (or injects) the behaviour, so check it
    # alongside the explicit `@behaviour`s. Loading may fail for project
    # modules that aren't compiled/loaded; those stay "unresolved".
    candidates = Enum.uniq(behaviours ++ uses)
    {callbacks, unresolved} = resolve_callbacks(candidates)
    unresolved_uses = Enum.filter(uses, &(&1 in unresolved))
    unresolved_behaviours = Enum.filter(behaviours, &(&1 in unresolved))

    cond do
      impl = impl_value(d) ->
        {:error, {:behaviour_callback, Map.put(info, :reason, {:impl, impl})}}

      behaviour = Enum.find_value(keys, &Map.get(callbacks, &1)) ->
        {:error, {:behaviour_callback, Map.put(info, :reason, {:behaviour, behaviour})}}

      Keyword.get(opts, :force, false) ->
        :ok

      unresolved_uses != [] or unresolved_behaviours != [] ->
        {:error,
         {:possible_callback,
          Map.merge(info, %{uses: unresolved_uses, behaviours: unresolved_behaviours})}}

      true ->
        :ok
    end
  end

  # `@impl true` / `@impl Mod` → the source text of the value; `@impl
  # false` (explicitly not a callback) and no `@impl` → nil.
  defp impl_value(%Definition{parts: %{attributes: attrs}}) do
    Enum.find_value(attrs, fn
      {:impl, {:@, _, [{:impl, _, [value]}]}} ->
        case unwrap_literal(value) do
          false -> nil
          v -> Macro.to_string(v)
        end

      _ ->
        nil
    end)
  end

  defp unwrap_literal({:__block__, _, [v]}) when is_atom(v), do: v
  defp unwrap_literal(v), do: v

  # `%{{name, arity} => "Behaviour"}` for every loadable behaviour, plus
  # the list of candidates that couldn't be loaded / aren't behaviours.
  defp resolve_callbacks(modules) do
    Enum.reduce(modules, {%{}, []}, fn name, {cbs, unresolved} ->
      mod = name_to_module(name)

      if Code.ensure_loaded?(mod) and function_exported?(mod, :behaviour_info, 1) do
        new =
          mod.behaviour_info(:callbacks)
          |> Enum.flat_map(&callback_keys/1)
          |> Map.new(&{&1, name})

        {Map.merge(new, cbs), unresolved}
      else
        {cbs, [name | unresolved]}
      end
    end)
  end

  # Macro callbacks are reported as `:"MACRO-name"` with the hidden
  # caller-env argument counted in the arity.
  defp callback_keys({name, arity}) do
    case Atom.to_string(name) do
      "MACRO-" <> macro -> [{String.to_atom(macro), arity - 1}]
      _ -> [{name, arity}]
    end
  end

  defp name_to_module(":" <> erlang), do: String.to_atom(erlang)
  defp name_to_module(name), do: Module.concat([name])

  # `use` targets and `@behaviour` values declared directly in the body
  # of `module` (nested modules' declarations don't count), as strings.
  defp module_behaviour_decls(source, module) do
    with {:ok, ast} <- Sourceror.parse_string(source),
         body when not is_nil(body) <- find_module_body(ast, "", module) do
      body
      |> body_nodes()
      |> Enum.reduce({[], []}, fn
        {:use, _, [target | _]}, {uses, behs} ->
          {[module_name(target, module) | uses], behs}

        {:@, _, [{:behaviour, _, [target]}]}, {uses, behs} ->
          {uses, [module_name(target, module) | behs]}

        _, acc ->
          acc
      end)
      |> then(fn {uses, behs} -> {Enum.reverse(uses), Enum.reverse(behs)} end)
    else
      _ -> {[], []}
    end
  end

  defp module_name({:__block__, _, [atom]}, _current) when is_atom(atom),
    do: ":" <> Atom.to_string(atom)

  defp module_name(ast, current), do: Adze.Names.module_ref(ast, current)

  defp find_module_body({:__block__, _, exprs}, prefix, target),
    do: Enum.find_value(exprs, &find_module_body(&1, prefix, target))

  defp find_module_body({:defmodule, _, [name_ast, [{_do, body}]]}, prefix, target) do
    name = Adze.Names.defmodule_name(name_ast, prefix)

    cond do
      name == target -> body
      true -> body |> body_nodes() |> Enum.find_value(&find_module_body(&1, name, target))
    end
  end

  defp find_module_body(_, _, _), do: nil

  defp body_nodes({:__block__, _, exprs}), do: exprs
  defp body_nodes(nil), do: []
  defp body_nodes(single), do: [single]

  defp flip_kind(:def), do: {:ok, :defp}
  defp flip_kind(:defmacro), do: {:ok, :defmacrop}
  defp flip_kind(:defguard), do: {:ok, :defguardp}
  defp flip_kind(:defdelegate), do: {:error, :cannot_be_private}
  defp flip_kind(other), do: {:error, {:already_private, %{kind: other}}}

  # --- find-callers + classification -------------------------------------

  # Default arguments make `helper/2` callable as `helper/1` too, and
  # those callers break just the same, so search every callable arity.
  defp run_find_callers(%Definition{} = d, opts) do
    target = {d.module, d.name, Definition.callable_arities(d)}

    fc_opts =
      case Keyword.get(opts, :files) do
        nil -> [mix_root: Keyword.get(opts, :mix_root, ".")]
        files -> [files: files]
      end

    FindCallers.find_callers(target, fc_opts)
  end

  # Every ref `find-callers` reports is a *qualified* reference
  # (`Mod.fun(...)`, `&Mod.fun/n`, `x |> Mod.fun`, `__MODULE__.fun(...)`)
  # — it never reports bare local calls. A qualified call to a private
  # function fails no matter where it sits, including inside the
  # module itself (`S.b()` / `__MODULE__.b()` within `S` is a remote
  # call), so every ref blocks the flip. We don't rewrite in-module
  # ones to local calls: a qualified self-call is often deliberate
  # (hot code upgrade in a receive loop, mocking/tracing), and making
  # it local would silently change semantics. `in_module` stays on
  # each ref so the user can tell self-references from other modules.
  defp classify_external(fc_result) do
    externals =
      Enum.flat_map(fc_result.files, fn {path, refs} ->
        Enum.map(refs, &Map.put(&1, :path, path))
      end)

    {:ok, externals}
  end

  defp check_no_externals([]), do: :ok
  defp check_no_externals(externals), do: {:error, {:external_callers, externals}}

  defp range_of(node) do
    case Sourceror.get_range(node) do
      %Sourceror.Range{start: start_kw, end: end_kw} ->
        %{start: Keyword.get(start_kw, :line), end: Keyword.get(end_kw, :line)}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # --- the actual edit ---------------------------------------------------
  #
  # Each clause sits on its own start line. Replace the leading
  # `def `/`defmacro `/`defguard ` keyword on each clause line with
  # its private variant. The leading indent is preserved by the
  # capture group; the trailing whitespace handle ensures we don't
  # match identifier-prefixes like `default`.

  defp flip_clauses(source, %Definition{kind: from_kind, parts: %{clauses: clauses}}, to_kind) do
    from_str = Atom.to_string(from_kind)
    to_str = Atom.to_string(to_kind)

    pattern = ~r/^(\s*)#{Regex.escape(from_str)}(\s)/

    clause_lines =
      clauses
      |> Enum.map(&range_of/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.start)
      |> MapSet.new()

    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, lineno} ->
      if MapSet.member?(clause_lines, lineno) do
        String.replace(line, pattern, "\\1#{to_str}\\2")
      else
        line
      end
    end)
    |> Enum.join("\n")
  end
end
