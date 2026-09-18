defmodule Adze.ProjectRewrite do
  @moduledoc """
  Thin wrapper around Igniter for project-wide write ops.

  All cross-file write ops in adze — `rename`, `extract!`'s caller
  rewriting (Session 6.5), `find-callers` (Session 7) — funnel through
  this module so the Igniter-shaped plumbing (build the rewrite, run
  the op, extract per-file diffs, write changes) lives in exactly one
  place.

  ## Lifecycle

      iex> {:ok, rewrite} = Adze.ProjectRewrite.new(mix_root: ".")
      iex> {:ok, rewrite, _report} =
      ...>   Adze.ProjectRewrite.rename_module(rewrite, MyApp.Old, MyApp.New)
      iex> {:ok, result} = Adze.ProjectRewrite.result(rewrite)
      iex> Adze.ProjectRewrite.write!(rewrite)

  `result/1` is dry-run shaped; it inspects the Igniter without
  touching disk. `write!/1` flushes the same Igniter to the filesystem.

  ## Working directory

  Igniter is built around the assumption that the current working
  directory is the project root — `Igniter.new/0` reads `.igniter.exs`
  and the dot formatter from `cwd`; `prepare_for_write/1` walks
  relative paths. The `Adze.ProjectRewrite` struct carries the project
  root so every operation can `cd` into it before delegating to
  Igniter and restore the previous `cwd` afterwards. Callers already
  in the right `cwd` (e.g. the `mix adze` task) pay no cost — the
  wrapper short-circuits when `root == File.cwd!()`.

  ## Test mode

      Adze.ProjectRewrite.new(files: %{"lib/foo.ex" => "..."})

  builds an in-memory test Igniter backed by
  `Igniter.Test.test_project/1`. No files are read from disk;
  `write!/1` is unsupported (raises). Used by the tests under
  `test/project_rewrite_test.exs` and `test/rename_test.exs`.
  """

  @enforce_keys [:igniter]
  defstruct [:igniter, :root, test?: false]

  @type t :: %__MODULE__{
          igniter: Igniter.t(),
          root: Path.t() | nil,
          test?: boolean()
        }

  @type opts :: [
          mix_root: Path.t(),
          files: %{Path.t() => String.t()},
          app_name: atom()
        ]

  @type ref :: %{path: Path.t(), line: non_neg_integer(), short: atom()}

  @type rename_report :: %{
          fixed_refs: [ref()],
          surviving_refs: [ref()]
        }

  @type result :: %{
          diffs: %{Path.t() => String.t()},
          moves: %{Path.t() => Path.t()},
          warnings: [String.t()],
          issues: [String.t()],
          notices: [String.t()]
        }

  @doc """
  Build a `ProjectRewrite` rooted at `mix_root:` (defaults to the
  current directory). When `files:` is supplied, returns an in-memory
  test rewrite instead — see the moduledoc.
  """
  @spec new(opts()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    cond do
      Keyword.has_key?(opts, :files) ->
        {:ok, %__MODULE__{igniter: Igniter.Test.test_project(opts), test?: true}}

      true ->
        root = Keyword.get(opts, :mix_root, ".") |> Path.expand()

        igniter =
          in_dir(root, fn ->
            Igniter.new()
            |> Igniter.include_all_elixir_files()
            |> include_extra_elixirc_paths()
          end)

        {:ok, %__MODULE__{igniter: igniter, root: root}}
    end
  end

  # Igniter's `include_all_elixir_files/1` only globs from `source_folders`
  # (defaults to `["lib", "test/support"]`) plus a hard-coded `test/` and
  # `config/`. Anything in the consuming project's `elixirc_paths` beyond
  # those — custom Credo checks under `credo/`, one-off scripts under
  # `priv/tasks/`, etc. — is silently skipped.
  #
  # We read `Mix.Project.config()[:elixirc_paths]` for the *current* Mix
  # env and add an explicit glob for each extra path. `mix adze` runs in
  # `:dev` by default, so paths that only appear in `elixirc_paths(:test)`
  # won't be scanned — set `MIX_ENV=test mix adze rename ...` (or extend
  # `.igniter.exs`'s `source_folders`) if you need that coverage.
  defp include_extra_elixirc_paths(igniter) do
    case Mix.Project.get() do
      nil ->
        igniter

      _ ->
        extras = (Mix.Project.config()[:elixirc_paths] || []) -- ["lib"]

        Enum.reduce(extras, igniter, fn path, ig ->
          Igniter.include_glob(ig, Path.join(path, "**/*.{ex,exs}"))
        end)
    end
  end

  @doc """
  Rename a module globally across the project. Wraps
  `Igniter.Refactors.Rename.rename_module/3` and adds the adze-specific
  follow-ups documented below.

  Returns `{:ok, rewrite, report}` where `report` describes the
  short-ref fix-up:

    * `fixed_refs` — bare `OldShort.fun(...)` AST nodes that Igniter's
      same-namespace pass left in place and adze patched on the
      caller's behalf.
    * `surviving_refs` — bare-short references the fix-up could not
      safely rewrite (no qualifying non-`as:` alias declaration in
      pre-rewrite content). Callers like `Adze.Rename` surface these
      as a warning and refuse to write without `force: true`.

  ## Follow-up work performed

    1. **Test-file move.** Igniter rewrites the test module's
       `defmodule` but doesn't move its file. We find the rewritten
       test source and schedule a move to its canonical-for-new-name
       path so the module name and file path stay in sync.
    2. **Short-ref fix-up.** Igniter's same-namespace rename has an
       upstream bug — the string-substitution pass rewrites the alias
       declaration before the AST pass runs, so bare
       `OldShort.fun(...)` call sites are no longer resolvable to the
       old aliases list and get left un-rewritten. Adze patches them
       itself in files that had a non-`as:` alias to the renamed
       module in their pre-rewrite content. Files without that
       evidence get left alone and reported in `surviving_refs`.
  """
  @spec rename_module(t(), module(), module()) :: {:ok, t(), rename_report()}
  def rename_module(%__MODULE__{} = rewrite, old_module, new_module)
      when is_atom(old_module) and is_atom(new_module) do
    igniter =
      in_dir(rewrite.root, fn ->
        rewrite.igniter
        |> Igniter.Refactors.Rename.rename_module(old_module, new_module)
        |> schedule_test_file_move(new_module)
      end)

    rewrite = %{rewrite | igniter: igniter}
    {rewrite, fixed, surviving} = apply_short_ref_fixup(rewrite, old_module, new_module)

    {:ok, rewrite, %{fixed_refs: fixed, surviving_refs: surviving}}
  end

  # After Igniter rewrites the test module's defmodule line, find the
  # rewritten test source (by its NEW name — the OLD name no longer
  # exists in the AST) and schedule a move to its canonical-for-new-
  # name path. If the test module doesn't exist or already sits at the
  # canonical path, this is a no-op.
  defp schedule_test_file_move(igniter, new_module) do
    new_test = test_module_for(new_module)

    case Igniter.Project.Module.find_module(igniter, new_test) do
      {:ok, {igniter, source, _zipper}} ->
        current_path = Rewrite.Source.get(source, :path)
        canonical_path = canonical_test_path(new_test)

        if current_path != canonical_path do
          Igniter.move_file(igniter, current_path, canonical_path, error_if_exists?: false)
        else
          igniter
        end

      _ ->
        igniter
    end
  end

  # MyApp.Foo → MyApp.FooTest (append "Test" to the last segment).
  defp test_module_for(mod) do
    parts = Module.split(mod)
    base = Enum.drop(parts, -1)
    last = List.last(parts)
    Module.concat(base ++ ["#{last}Test"])
  end

  # MyApp.FooTest → "test/my_app/foo_test.exs".
  defp canonical_test_path(test_mod) do
    "test/" <> Macro.underscore(test_mod) <> ".exs"
  end

  # Single pass over every changed file: parse the post-rewrite AST,
  # collect `{:__aliases__, _, [OldShort | _]}` survivors, decide
  # whether the file is safe to patch (had a non-`as:` alias to the
  # renamed module in its pre-rewrite content), and either:
  #
  #   * `:fix`     — rewrite survivors to NewShort, update the source,
  #                  record refs in `fixed`.
  #   * `:keep`    — leave the file alone, record refs in `surviving`.
  #   * `:nothing` — no survivors, no work.
  #
  # The previous implementation walked every changed file twice (once
  # to fix-up, once to find what survived). One pass is enough: the
  # "surviving" output is exactly the survivors we chose not to fix.
  defp apply_short_ref_fixup(rewrite, from_module, to_module) do
    old_short = short_atom(from_module)
    new_short = short_atom(to_module)

    rewrite
    |> changed_sources()
    |> Enum.reduce({rewrite, [], []}, fn source, {rw, fixed, surviving} ->
      case classify_source(source, old_short, new_short) do
        {:fix, new_source, refs} ->
          {put_source(rw, new_source), fixed ++ refs, surviving}

        {:keep, refs} ->
          {rw, fixed, surviving ++ refs}

        :nothing ->
          {rw, fixed, surviving}
      end
    end)
    |> then(fn {rw, fixed, surviving} ->
      {rw, Enum.sort_by(fixed, &{&1.path, &1.line}), Enum.sort_by(surviving, &{&1.path, &1.line})}
    end)
  end

  defp classify_source(source, old_short, new_short) do
    content = Rewrite.Source.get(source, :content)
    path = Rewrite.Source.get(source, :path)

    with {:ok, ast} <- Sourceror.parse_string(content),
         survivors when survivors != [] <- collect_short_refs(ast, old_short, path) do
      if pre_rewrite_had_bare_alias?(source, old_short) do
        new_ast = rewrite_short(ast, old_short, new_short)

        case render(new_ast) do
          {:ok, new_content} ->
            updated = Rewrite.Source.update(source, :content, new_content)
            {:fix, updated, survivors}

          {:error, _reason} ->
            {:keep, survivors}
        end
      else
        {:keep, survivors}
      end
    else
      _ -> :nothing
    end
  end

  defp collect_short_refs(ast, short, path) do
    {_ast, refs} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, meta, [^short | _]} = node, acc ->
          line = Keyword.get(meta, :line, 0)
          {node, [%{path: path, line: line, short: short} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(refs)
  end

  defp pre_rewrite_had_bare_alias?(source, old_short) do
    case source |> Rewrite.Source.get(:content, 1) |> Sourceror.parse_string() do
      {:ok, ast} -> had_bare_alias_to_short?(ast, old_short)
      _ -> false
    end
  end

  # Did the file declare an `alias` whose target ended in `OldShort`
  # *without* an `as:` clause? `as:` aliases don't produce bare
  # `OldShort.*` call sites — the binding is rewritten to the `as:`
  # value — so they aren't evidence that bare refs were resolving via
  # this alias.
  defp had_bare_alias_to_short?(ast, old_short) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        node, true ->
          {node, true}

        {:alias, _, args} = node, false ->
          {node, alias_targets_short_no_as?(args, old_short)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp alias_targets_short_no_as?(args, short) do
    case args do
      # alias Foo.Bar.OldShort
      [{:__aliases__, _, parts}] ->
        List.last(parts) == short

      # alias Foo.Bar.OldShort, opts
      [{:__aliases__, _, parts}, opts] when is_list(opts) ->
        List.last(parts) == short and not has_as_opt?(opts)

      # alias Foo.{A, OldShort}
      [{{:., _, [{:__aliases__, _, _prefix}, :{}]}, _, members}] ->
        Enum.any?(members, fn
          {:__aliases__, _, parts} -> List.last(parts) == short
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp has_as_opt?(opts) do
    Enum.any?(opts, fn
      {key, _value} -> unwrap_atom(key) == :as
      _ -> false
    end)
  end

  defp unwrap_atom({:__block__, _, [a]}) when is_atom(a), do: a
  defp unwrap_atom(a) when is_atom(a), do: a
  defp unwrap_atom(_), do: nil

  defp short_atom(module) do
    module |> Module.split() |> List.last() |> String.to_atom()
  end

  defp rewrite_short(ast, old_short, new_short) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, [^old_short | rest]} ->
        {:__aliases__, meta, [new_short | rest]}

      node ->
        node
    end)
  end

  # Sourceror's `to_string/2` preserves comments and formatting from
  # parsed metadata. Pass `locals_without_parens: []` to skip the
  # automatic formatter lookup — not load-bearing for the F3 fixup
  # path, which only rewrites `__aliases__` segments.
  defp render(ast) do
    rendered = Sourceror.to_string(ast, locals_without_parens: [])
    result = if String.ends_with?(rendered, "\n"), do: rendered, else: rendered <> "\n"
    {:ok, result}
  rescue
    e -> {:error, {:render, e}}
  end

  defp changed_sources(%__MODULE__{igniter: igniter}) do
    igniter.rewrite
    |> Rewrite.sources()
    |> Enum.filter(&Igniter.changed?/1)
  end

  defp put_source(%__MODULE__{igniter: igniter} = rewrite, %Rewrite.Source{} = source) do
    new_rewrite = Rewrite.update!(igniter.rewrite, source)
    %{rewrite | igniter: %{igniter | rewrite: new_rewrite}}
  end

  @doc """
  Rewrite call sites of `{old_module, old_function}` to
  `{new_module, new_function}` across the project. Wraps
  `Igniter.Refactors.Rename.rename_function/4`.

  Pass `arity: n` (or a list) to narrow to a specific arity; defaults
  to `:any`. When the function definition has already been removed
  from `old_module` (e.g. by `Adze.Extract` cutting it before this
  runs), Igniter's def-move step is a no-op and only the call-site
  rewrites take effect.
  """
  @spec rename_function(t(), {module(), atom()}, {module(), atom()}, keyword()) :: {:ok, t()}
  def rename_function(%__MODULE__{} = rewrite, {old_mod, old_fun}, {new_mod, new_fun}, opts \\ [])
      when is_atom(old_mod) and is_atom(old_fun) and is_atom(new_mod) and is_atom(new_fun) do
    # Igniter's `rename_function` drives its call-site rewrite via
    # `update_all_elixir_files`, which short-circuits when the
    # `included_all_elixir_files?` flag is already set in assigns.
    # `ProjectRewrite.new/1` pre-includes (so we can scan for callers
    # eagerly), which would otherwise turn the call-site pass into a
    # silent no-op. Clear the flag for the duration of this call;
    # Igniter re-asserts it on the way out.
    igniter =
      in_dir(rewrite.root, fn ->
        rewrite.igniter
        |> clear_included_flag()
        |> Igniter.Refactors.Rename.rename_function(
          {old_mod, old_fun},
          {new_mod, new_fun},
          opts
        )
      end)

    {:ok, %{rewrite | igniter: igniter}}
  end

  defp clear_included_flag(%Igniter{assigns: assigns} = igniter) do
    case assigns[:private] do
      %{} = private ->
        new_private = Map.delete(private, :included_all_elixir_files?)
        %{igniter | assigns: Map.put(assigns, :private, new_private)}

      _ ->
        igniter
    end
  end

  @doc """
  Replace the content of an existing tracked source. Used by
  `Adze.Extract` to inject its in-file rewrite (cut + caller fix-up +
  alias insert) into the project before the cross-file pass runs.
  """
  @spec put_content(t(), Path.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def put_content(%__MODULE__{igniter: igniter} = rewrite, path, content)
      when is_binary(path) and is_binary(content) do
    rel = relative_path(path, rewrite.root)

    case Rewrite.source(igniter.rewrite, rel) do
      {:ok, source} ->
        updated = Rewrite.Source.update(source, :content, content)
        new_rewrite = Rewrite.update!(igniter.rewrite, updated)
        {:ok, %{rewrite | igniter: %{igniter | rewrite: new_rewrite}}}

      {:error, _} ->
        {:error, {:source_not_found, rel}}
    end
  end

  @doc """
  Add a brand-new file to the project. Wraps
  `Igniter.create_new_file/4` so the eventual `write!/1` writes it
  alongside any other rewrites.
  """
  @spec create_file(t(), Path.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def create_file(%__MODULE__{igniter: igniter} = rewrite, path, content)
      when is_binary(path) and is_binary(content) do
    rel = relative_path(path, rewrite.root)

    igniter =
      in_dir(rewrite.root, fn ->
        Igniter.create_new_file(igniter, rel, content)
      end)

    case igniter.issues do
      [] -> {:ok, %{rewrite | igniter: igniter}}
      issues -> {:error, {:issues, issues}}
    end
  end

  @doc """
  Extract a dry-run-shaped result from the rewrite without writing.

  `diffs` keys are file paths; values are plain-text unified-ish diffs
  rendered by Rewrite (no ANSI color). `moves` keys are pre-move
  paths, values are post-move paths. Errors/warnings are surfaced
  separately so the caller can decide whether to refuse to write.
  """
  @spec result(t()) :: {:ok, result()}
  def result(%__MODULE__{igniter: igniter}) do
    sources =
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.filter(&Igniter.changed?/1)
      |> Enum.sort_by(& &1.path)

    diffs =
      Map.new(sources, fn source ->
        {Rewrite.Source.get(source, :path), source_diff(source)}
      end)

    {:ok,
     %{
       diffs: diffs,
       moves: igniter.moves || %{},
       warnings: igniter.warnings || [],
       issues: igniter.issues || [],
       notices: igniter.notices || []
     }}
  end

  @doc """
  Flush the rewrite to disk. Same as `write!/1`, but converts
  filesystem errors (`File.Error`, `File.RenameError`) into
  `{:error, {:file_write, reason}}` instead of raising. Still raises
  `ArgumentError` for programmer errors -- test-mode rewrites and
  rewrites carrying unresolved Igniter issues -- since those indicate
  a caller bug rather than a recoverable I/O failure.
  """
  @spec write(t()) :: :ok | {:error, term()}
  def write(%__MODULE__{} = rewrite) do
    write!(rewrite)
  rescue
    e in [File.Error, File.RenameError] -> {:error, {:file_write, e.reason}}
  end

  @doc """
  Flush the rewrite to disk. Refuses to write when the rewrite is in
  test mode or carries unresolved issues.
  """
  @spec write!(t()) :: :ok
  def write!(%__MODULE__{test?: true}) do
    raise ArgumentError,
          "ProjectRewrite.write!/1 is unsupported on a test-mode rewrite. " <>
            "Use Igniter.Test.apply_igniter/1 for assertions."
  end

  def write!(%__MODULE__{igniter: %Igniter{issues: [_ | _] = issues}}) do
    raise ArgumentError,
          "Refusing to write — Igniter has issues: #{Enum.join(issues, "; ")}"
  end

  def write!(%__MODULE__{igniter: igniter, root: root}) do
    in_dir(root, fn ->
      prepped = Igniter.prepare_for_write(igniter)
      {:ok, _} = Rewrite.write_all(prepped.rewrite)

      Enum.each(prepped.moves, fn {from, to} ->
        File.mkdir_p!(Path.dirname(to))
        if File.exists?(from), do: File.rename!(from, to)
      end)

      :ok
    end)
  end

  # --- helpers -----------------------------------------------------------

  # Igniter tracks sources by paths relative to the rewrite's cwd.
  # When callers hand us an absolute path or one anchored at a
  # different cwd, normalize against the rewrite root so lookup
  # succeeds. Test-mode rewrites carry `root: nil`; in that case the
  # path is already in the form Igniter stored it.
  defp relative_path(path, nil), do: path

  defp relative_path(path, root) do
    expanded = Path.expand(path)
    root = Path.expand(root)

    case Path.relative_to(expanded, root) do
      ^expanded -> path
      rel -> rel
    end
  end

  defp in_dir(nil, fun), do: fun.()

  defp in_dir(dir, fun) do
    cwd = File.cwd!()
    target = Path.expand(dir)

    if target == cwd do
      fun.()
    else
      try do
        File.cd!(target)
        fun.()
      after
        File.cd!(cwd)
      end
    end
  end

  # Rewrite renders new-file content and modified-file content
  # differently. For both we want a plain-text representation:
  #
  #   * brand-new file (from: :string) → render as a "+"-prefixed body.
  #   * modified existing file → use Rewrite's built-in line-diff
  #     (`Rewrite.Source.diff/2`) with color disabled.
  defp source_diff(source) do
    content = Rewrite.Source.get(source, :content)

    cond do
      Rewrite.Source.from?(source, :string) and String.valid?(content) ->
        new_file_marker(source, content)

      String.valid?(content) ->
        source
        |> Rewrite.Source.diff(color: false)
        |> IO.iodata_to_binary()

      true ->
        ""
    end
  end

  defp new_file_marker(source, content) do
    path = Rewrite.Source.get(source, :path)
    body = content |> String.split("\n") |> Enum.map_join("\n", &("+ " <> &1))
    "Create: #{path}\n\n#{body}\n"
  end
end
