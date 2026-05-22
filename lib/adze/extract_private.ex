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
    * Attached `@spec` / `@doc` / `@impl` / etc. are left in place. A
      `@spec` on a `defp` is allowed by the compiler; an `@impl` on a
      private callable is rejected, but flipping a function with `@impl`
      to private is almost certainly wrong anyway — `find-callers`
      would normally surface the behaviour-callback callers and refuse
      the flip. We let the compiler complain if the user forces it via
      a future override.

  ## Safety

  External = a caller in any file other than the source file, OR a
  caller in the source file whose enclosing `defmodule` is not the
  target's module. The latter catches the case where a file holds
  multiple modules and a sibling calls the target via its
  fully-qualified name. We rely on `Adze.FindCallers` to find the
  refs, then re-parse each affected file to determine each ref's
  enclosing module for classification.

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
          path: Path.t(),
          mix_root: Path.t(),
          files: %{Path.t() => String.t()},
          include_attrs: [atom()]
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
         {:ok, path} <- fetch_opt(opts, :path),
         {:ok, definition} <- find_definition(source, def_spec, opts),
         {:ok, to_kind} <- flip_kind(definition.kind),
         :ok <- ensure_public(definition),
         {:ok, fc_result} <- run_find_callers(definition, opts),
         {:ok, externals} <- classify_external(fc_result, path, definition),
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
      {:ok, source} -> extract_private(source, Keyword.put(opts, :path, path))
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
    {name, arity} = parse_spec(spec)
    from_module = Keyword.get(opts, :from_module)

    with {:ok, defs} <- Definition.list(source, opts) do
      matches = Enum.filter(defs, &(&1.name == name and &1.arity == arity))

      pick_match(matches, name, arity, from_module)
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
        {:error,
         {:from_module_mismatch, %{from: from, candidates: Enum.map(many, & &1.module)}}}

      picked ->
        {:ok, picked}
    end
  end

  defp parse_spec({n, a}) when is_atom(n) and is_integer(a), do: {n, a}

  defp parse_spec(str) when is_binary(str) do
    [name, arity] = String.split(str, "/", parts: 2)
    {String.to_atom(name), String.to_integer(arity)}
  end

  defp ensure_public(%Definition{visibility: :public}), do: :ok

  defp ensure_public(%Definition{visibility: :private, kind: kind, name: n, arity: a}),
    do: {:error, {:already_private, %{kind: kind, definition: {n, a}}}}

  defp flip_kind(:def), do: {:ok, :defp}
  defp flip_kind(:defmacro), do: {:ok, :defmacrop}
  defp flip_kind(:defguard), do: {:ok, :defguardp}
  defp flip_kind(:defdelegate), do: {:error, :cannot_be_private}
  defp flip_kind(other), do: {:error, {:already_private, %{kind: other}}}

  # --- find-callers + classification -------------------------------------

  defp run_find_callers(%Definition{} = d, opts) do
    target = "#{d.module}.#{d.name}/#{d.arity}"

    fc_opts =
      case Keyword.get(opts, :files) do
        nil -> [mix_root: Keyword.get(opts, :mix_root, ".")]
        files -> [files: files]
      end

    FindCallers.find_callers(target, fc_opts)
  end

  # `find-callers` already attaches `in_module` to each ref (the
  # innermost enclosing `defmodule` at the ref's line). A ref is
  # "internal" iff it's in the same file *and* its `in_module` is the
  # target's module — that catches sibling-module-in-same-file refs as
  # external while leaving in-module refs alone.
  defp classify_external(fc_result, source_path, %Definition{module: source_module}) do
    externals =
      fc_result.files
      |> Enum.flat_map(fn {path, refs} ->
        Enum.map(refs, &Map.put(&1, :path, path))
      end)
      |> Enum.reject(fn r ->
        same_file?(r.path, source_path) and r.in_module == source_module
      end)

    {:ok, externals}
  end

  defp check_no_externals([]), do: :ok
  defp check_no_externals(externals), do: {:error, {:external_callers, externals}}

  # Normalize both sides so a relative path from Igniter's rewrite root
  # compares equal to the same relative path the caller passed in via
  # `--file`. `Path.expand/1` resolves `.`/`..` and absolutizes against
  # cwd — it does not require the path to exist.
  defp same_file?(a, b), do: Path.expand(a) == Path.expand(b)

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
