defmodule Adze.ProjectRewrite do
  @moduledoc """
  Thin wrapper around Igniter for project-wide write ops.

  All project-wide ops in adze — `rename`, `extract!`'s caller
  rewriting, and the read-only `find-callers` — funnel through
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

  alias Adze.AliasScope

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
      safely attribute to the renamed module (no non-`as:` alias to it
      in scope). Callers like `Adze.Rename` surface these
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
       old aliases list and get left un-rewritten. Adze patches each
       one whose lexical scope has a non-`as:` alias to the renamed
       module. A bare ref with no alias for the short name in scope is
       left alone and reported in `surviving_refs`; one bound to some
       other module (`alias Other.OldShort`, `as:`, a nested
       `defmodule`) is not a reference to the renamed module and is
       neither touched nor reported.
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

  # Single pass over every changed file: parse the post-rewrite AST and
  # walk it with Elixir's lexical alias rules (`Adze.AliasScope`),
  # deciding for each `{:__aliases__, _, [OldShort | _]}` what the short
  # name refers to at that point:
  #
  #   * the renamed module — a non-`as:` `alias NewModule` is in scope
  #     (Igniter rewrote `alias OldModule` to it, leaving the bare
  #     `OldShort` refs behind) → rewrite to `NewShort`, report `fixed`;
  #   * nothing (no alias binds `OldShort`), or a surviving
  #     `alias OldModule` → can't tell / still broken → leave it,
  #     report `surviving`;
  #   * some other module (`alias Other.OldShort`, `as: OldShort`, a
  #     nested `defmodule OldShort`) → not a reference to the renamed
  #     module at all; leave it alone and don't report it.
  #
  # A file is re-rendered only when something was fixed.
  defp apply_short_ref_fixup(rewrite, from_module, to_module) do
    ctx = %{
      old_short: short_atom(from_module),
      new_short: short_atom(to_module),
      old_str: inspect(from_module),
      new_str: inspect(to_module)
    }

    rewrite
    |> changed_sources()
    |> Enum.reduce({rewrite, [], []}, fn source, {rw, fixed, surviving} ->
      case classify_source(source, ctx) do
        {:fix, new_source, new_fixed, new_surviving} ->
          {put_source(rw, new_source), fixed ++ new_fixed, surviving ++ new_surviving}

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

  defp classify_source(source, ctx) do
    content = Rewrite.Source.get(source, :content)
    path = Rewrite.Source.get(source, :path)

    case Sourceror.parse_string(content) do
      {:ok, ast} ->
        ctx = Map.put(ctx, :mark_renamed?, mark_renamed?(source, ctx))
        {new_ast, fixed, surviving} = walk_short_refs(ast, ctx, path)

        cond do
          fixed == [] and surviving == [] ->
            :nothing

          fixed == [] ->
            {:keep, surviving}

          true ->
            case render(new_ast) do
              {:ok, new_content} ->
                {:fix, Rewrite.Source.update(source, :content, new_content), fixed, surviving}

              {:error, _reason} ->
                {:keep, fixed ++ surviving}
            end
        end

      _ ->
        :nothing
    end
  end

  # Whether a non-`as:` `alias NewModule` in the post-rewrite source
  # means "`OldShort` here meant the renamed module". Not when the short
  # name didn't change (`alias NewModule` binds `OldShort` itself, so
  # those refs already resolve), and not when the file already aliased
  # `NewModule` before the rename — that declaration is
  # indistinguishable from a rewritten one, so a bare `OldShort` near it
  # can't be attributed to the rename.
  defp mark_renamed?(source, ctx) do
    ctx.old_short != ctx.new_short and not pre_rewrite_aliased?(source, ctx.new_str)
  end

  defp pre_rewrite_aliased?(source, module) do
    case source |> Rewrite.Source.get(:content, 1) |> Sourceror.parse_string() do
      {:ok, ast} ->
        {_, found?} =
          Macro.prewalk(ast, false, fn
            {:alias, _, args} = node, false when is_list(args) ->
              {node, Enum.any?(AliasScope.alias_bindings(args, nil), &(&1.module == module))}

            node, acc ->
              {node, acc}
          end)

        found?

      _ ->
        false
    end
  end

  defp walk_short_refs(ast, ctx, path) do
    {new_ast, acc} =
      Macro.traverse(
        ast,
        %{scope: [], aliases: %{}, stack: [], fixed: [], surviving: []},
        &short_ref_pre(&1, &2, ctx, path),
        &short_ref_post/2
      )

    {new_ast, Enum.reverse(acc.fixed), Enum.reverse(acc.surviving)}
  end

  # The `defmodule` name is resolved against the aliases *outside* the
  # module (it can be a renamed ref itself: `defmodule OldShort.Sub`),
  # then tagged so the child visit skips it. Its implicit alias goes
  # below the scope push so it outlives the module.
  defp short_ref_pre({:defmodule, meta, [name_ast, body]}, acc, ctx, path) do
    current = current_module(acc.scope)
    head_bound? = head_bound?(name_ast, acc.aliases)
    module_name = Adze.Names.defmodule_name(name_ast, current || "")
    {name_ast, acc} = classify_short_ref(name_ast, acc, ctx, path, :defmodule)

    aliases =
      case AliasScope.implicit_alias(name_ast, current, head_bound?) do
        nil -> acc.aliases
        {name, module} -> bind(acc.aliases, %{name: name, module: module, as?: false}, ctx)
      end

    acc = %{
      acc
      | scope: [module_name | acc.scope],
        aliases: aliases,
        stack: [aliases | acc.stack]
    }

    {{:defmodule, meta, [skip_tag(name_ast), body]}, acc}
  end

  defp short_ref_pre({:alias, _, args} = node, acc, ctx, _path) when is_list(args) do
    aliases =
      args
      |> AliasScope.alias_bindings(current_module(acc.scope))
      |> Enum.reduce(acc.aliases, &bind(&2, &1, ctx))

    {node, %{acc | aliases: aliases}}
  end

  defp short_ref_pre({:__aliases__, _, _} = node, acc, ctx, path),
    do: classify_short_ref(node, acc, ctx, path, :ref)

  defp short_ref_pre(node, acc, _ctx, _path) do
    if AliasScope.scope_node?(node),
      do: {node, %{acc | stack: [acc.aliases | acc.stack]}},
      else: {node, acc}
  end

  defp short_ref_post({:defmodule, meta, [name_ast, body]}, acc) do
    acc = %{acc | scope: tl(acc.scope), aliases: hd(acc.stack), stack: tl(acc.stack)}
    {{:defmodule, meta, [skip_untag(name_ast), body]}, acc}
  end

  defp short_ref_post(node, acc) do
    if AliasScope.scope_node?(node),
      do: {node, %{acc | aliases: hd(acc.stack), stack: tl(acc.stack)}},
      else: {node, acc}
  end

  # An alias binding, plus — for a non-`as:` alias to the new module —
  # the note that a bare `OldShort` in this scope meant the renamed module.
  defp bind(aliases, %{name: name, module: module, as?: as?}, ctx) do
    aliases = Map.put(aliases, name, module)

    if ctx.mark_renamed? and not as? and module == ctx.new_str,
      do: Map.put(aliases, Atom.to_string(ctx.old_short), :renamed),
      else: aliases
  end

  defp classify_short_ref({:__aliases__, meta, [head | rest]} = node, acc, ctx, path, role)
       when head == ctx.old_short do
    ref = %{path: path, line: Keyword.get(meta, :line, 0), short: head}

    cond do
      Keyword.get(meta, :adze_skip, false) ->
        {node, acc}

      Map.get(acc.aliases, Atom.to_string(head)) == :renamed ->
        {{:__aliases__, meta, [ctx.new_short | rest]}, %{acc | fixed: [ref | acc.fixed]}}

      # A `defmodule` name that isn't a renamed ref defines a module of
      # its own; it isn't a reference that could have been missed.
      role == :defmodule ->
        {node, acc}

      Map.get(acc.aliases, Atom.to_string(head)) in [nil, ctx.old_str] ->
        {node, %{acc | surviving: [ref | acc.surviving]}}

      true ->
        {node, acc}
    end
  end

  defp classify_short_ref(node, acc, _ctx, _path, _role), do: {node, acc}

  defp head_bound?({:__aliases__, _, [first | _]}, aliases) when is_atom(first),
    do: Map.has_key?(aliases, Atom.to_string(first))

  defp head_bound?(_name_ast, _aliases), do: false

  defp skip_tag({:__aliases__, meta, parts}),
    do: {:__aliases__, [{:adze_skip, true} | meta], parts}

  defp skip_tag(other), do: other

  defp skip_untag({:__aliases__, meta, parts}),
    do: {:__aliases__, Keyword.delete(meta, :adze_skip), parts}

  defp skip_untag(other), do: other

  defp current_module([]), do: nil
  defp current_module([top | _]), do: top

  defp short_atom(module) do
    module |> Module.split() |> List.last() |> String.to_atom()
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

  @doc """
  Paths of project files (other than `exclude`) containing
  `import <module>` (or, with `use_imports?: true`, `use <module>`)
  whose options could bring in one of `keys` — `[{name, arity, class}]`
  with `class` `:macro` or `:function`. Calls through an import are
  bare, so no call-site rewrite can retarget them. Literal `only:` /
  `except:` lists and `only: :macros | :functions` are honoured.
  """
  @spec importers(
          t(),
          String.t(),
          [{atom(), non_neg_integer(), :macro | :function}],
          [Path.t()],
          keyword()
        ) ::
          [Path.t()]
  def importers(%__MODULE__{igniter: igniter, root: root}, module, keys, exclude, opts \\ []) do
    parts = module |> String.split(".") |> Enum.map(&String.to_atom/1)
    exclude = Enum.map(exclude, &relative_path(&1, root))
    directives = if Keyword.get(opts, :use_imports?, false), do: [:import, :use], else: [:import]

    for source <- Rewrite.sources(igniter.rewrite),
        path = Rewrite.Source.get(source, :path),
        String.ends_with?(path, [".ex", ".exs"]),
        path not in exclude,
        imports_module?(Rewrite.Source.get(source, :content), parts, keys, directives),
        do: path
  end

  defp imports_module?(content, parts, keys, directives) do
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        {_, found} =
          Macro.prewalk(ast, false, fn
            {kind, _, [{:__aliases__, _, ^parts} | opts]} = node, acc
            when kind in [:import, :use] ->
              covers? = kind in directives and (kind == :use or import_covers?(opts, keys))
              {node, acc or covers?}

            node, acc ->
              {node, acc}
          end)

        found

      _ ->
        false
    end
  end

  defp import_covers?([opts], keys) when is_list(opts) do
    only = Keyword.get(opts, :only)
    except = Keyword.get(opts, :except)

    Enum.any?(keys, fn {n, a, class} = _key ->
      only_ok?(only, n, a, class) and not except_hit?(except, n, a)
    end)
  end

  defp import_covers?(_, _keys), do: true

  defp only_ok?(nil, _, _, _), do: true
  defp only_ok?(:macros, _, _, class), do: class == :macro
  defp only_ok?(:functions, _, _, class), do: class == :function
  defp only_ok?(:sigils, _, _, _), do: false

  defp only_ok?(list, n, a, _) when is_list(list),
    do:
      Enum.any?(list, fn
        {n2, a2} when is_atom(n2) and is_integer(a2) -> {n2, a2} == {n, a}
        _ -> true
      end)

  defp only_ok?(_, _, _, _), do: true

  defp except_hit?(list, n, a) when is_list(list), do: {n, a} in list
  defp except_hit?(_, _, _), do: false

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

  @keep_marker "__adze_keep__"

  @doc """
  Shield piped remote calls whose real arity (written args + the piped
  one) is not in `allowed` from a following `rename_function` pass.

  Igniter matches the *written* arity, so `v |> S.foo(2)` (really
  `foo/2`) looks like `foo/1`. `allowed` maps function name to the list
  of real arities that are being moved. Matching calls get a marker
  inserted into the function name (before a trailing `?`/`!`); `unprotect_calls/1` removes it.
  """
  @spec protect_piped_calls(t(), %{atom() => [non_neg_integer()]}) :: t()
  def protect_piped_calls(%__MODULE__{} = rewrite, allowed) when is_map(allowed) do
    map_elixir_sources(rewrite, fn content ->
      case protect_edits(content, allowed) do
        {_, []} -> content
        edits -> apply_insertions(edits)
      end
    end)
  end

  @doc "Undo `protect_piped_calls/2`."
  @spec unprotect_calls(t()) :: t()
  def unprotect_calls(%__MODULE__{} = rewrite) do
    map_elixir_sources(rewrite, fn content ->
      String.replace(content, @keep_marker, "")
    end)
  end

  defp map_elixir_sources(%__MODULE__{igniter: igniter} = rewrite, fun) do
    Enum.reduce(Rewrite.sources(igniter.rewrite), rewrite, fn source, rw ->
      path = Rewrite.Source.get(source, :path)

      if String.ends_with?(path, [".ex", ".exs"]) do
        content = Rewrite.Source.get(source, :content)

        case fun.(content) do
          ^content -> rw
          new -> put_source(rw, Rewrite.Source.update(source, :content, new))
        end
      else
        rw
      end
    end)
  end

  # Charlist indexes at which to insert the marker, for piped remote
  # calls with a real arity outside `allowed`. The charlist and line
  # index are only built once a candidate pipe turns up.
  defp protect_edits(content, allowed) do
    with {:ok, ast} <- Code.string_to_quoted(content, columns: true, token_metadata: true),
         [_ | _] = candidates <- candidate_calls(ast, allowed) do
      chars = String.to_charlist(content)
      line_starts = line_starts(chars)

      idxs =
        for {name, line, col} <- candidates,
            {:ok, start} <- [Map.fetch(line_starts, line)],
            {:ok, idx} <- [name_index(chars, start + col, name)],
            uniq: true,
            do: idx + marker_offset(name)

      {chars, idxs}
    else
      _ -> {[], []}
    end
  end

  # `{name, line, col}` of the dot in each piped remote call whose real
  # arity is outside `allowed`.
  defp candidate_calls(ast, allowed) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:|>, _, [_lhs, {{:., dot_meta, [_mod, name]}, _, args}]} = node, acc
        when is_atom(name) and is_list(args) ->
          with %{^name => arities} <- allowed,
               false <- (length(args) + 1) in arities,
               line when is_integer(line) <- dot_meta[:line],
               col when is_integer(col) <- dot_meta[:column] do
            {node, [{name, line, col} | acc]}
          else
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # Map of line number => charlist index of its first character.
  defp line_starts(chars) do
    {starts, _, _} =
      chars
      |> Enum.reduce({%{1 => 0}, 0, 1}, fn
        ?\n, {m, i, l} -> {Map.put(m, l + 1, i + 1), i + 1, l + 1}
        _, {m, i, l} -> {m, i + 1, l}
      end)

    starts
  end

  # `dot_idx` is the index just past the dot (columns are 1-based). The
  # name may follow on a later line, after whitespace or comments.
  defp name_index(chars, dot_idx, name) do
    rest = Enum.drop(chars, dot_idx - 1)

    case rest do
      [?. | after_dot] -> find_name(after_dot, dot_idx, Atom.to_charlist(name))
      _ -> :error
    end
  end

  defp find_name([c | rest], idx, name) when c in [?\s, ?\t, ?\n, ?\r],
    do: find_name(rest, idx + 1, name)

  defp find_name([?# | rest], idx, name) do
    {comment, tail} = Enum.split_while(rest, &(&1 != ?\n))
    find_name(tail, idx + 1 + length(comment), name)
  end

  defp find_name(rest, idx, name) do
    if List.starts_with?(rest, name), do: {:ok, idx}, else: :error
  end

  # Where the marker goes, relative to the start of the name. It must sit
  # before a trailing `?`/`!` -- `foo?__adze_keep__` would not parse.
  defp marker_offset(name) do
    str = Atom.to_string(name)
    len = String.length(str)
    if String.ends_with?(str, ["?", "!"]), do: len - 1, else: len
  end

  defp apply_insertions({chars, idxs}) do
    idxs
    |> Enum.sort(:desc)
    |> Enum.reduce(chars, fn idx, chars ->
      {before, rest} = Enum.split(chars, idx)
      before ++ String.to_charlist(@keep_marker) ++ rest
    end)
    |> List.to_string()
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
    guard_writable!(rewrite)

    case do_write(rewrite) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file_write, reason}}
    end
  rescue
    e in [File.Error, File.RenameError] -> {:error, {:file_write, e.reason}}
  end

  @doc """
  Flush the rewrite to disk. Refuses to write when the rewrite is in
  test mode or carries unresolved issues. Raises `RuntimeError` when
  any file cannot be written (e.g. it changed on disk after being
  read); files already written are restored first.
  """
  @spec write!(t()) :: :ok
  def write!(%__MODULE__{} = rewrite) do
    guard_writable!(rewrite)

    case do_write(rewrite) do
      :ok -> :ok
      {:error, reason} -> raise "ProjectRewrite.write!/1 failed: #{inspect(reason)}"
    end
  end

  defp guard_writable!(%__MODULE__{test?: true}) do
    raise ArgumentError,
          "ProjectRewrite.write!/1 is unsupported on a test-mode rewrite. " <>
            "Use Igniter.Test.apply_igniter/1 for assertions."
  end

  defp guard_writable!(%__MODULE__{igniter: %Igniter{issues: [_ | _] = issues}}) do
    raise ArgumentError,
          "Refusing to write — Igniter has issues: #{Enum.join(issues, "; ")}"
  end

  defp guard_writable!(_), do: :ok

  # All-or-nothing: snapshot every file we're about to touch, and on
  # any failure restore the snapshot so a partial write never lingers.
  defp do_write(%__MODULE__{igniter: igniter, root: root}) do
    in_dir(root, fn ->
      prepped = Igniter.prepare_for_write(igniter)

      snapshot =
        prepped.rewrite
        |> Rewrite.sources()
        |> Enum.filter(&Igniter.changed?/1)
        |> Enum.map(& &1.path)
        |> Enum.concat(Enum.flat_map(prepped.moves, fn {from, to} -> [from, to] end))
        |> Enum.uniq()
        |> Map.new(fn path ->
          case File.read(path) do
            {:ok, content} -> {path, content}
            {:error, _} -> {path, nil}
          end
        end)

      try do
        case Rewrite.write_all(prepped.rewrite) do
          {:ok, _} ->
            Enum.each(prepped.moves, fn {from, to} ->
              File.mkdir_p!(Path.dirname(to))
              if File.exists?(from), do: File.rename!(from, to)
            end)

            :ok

          {:error, errors, _rewrite} ->
            restore(snapshot)
            {:error, Enum.map(errors, &error_reason/1)}
        end
      rescue
        e in [File.Error, File.RenameError] ->
          restore(snapshot)
          {:error, e.reason}
      end
    end)
  end

  defp error_reason(%{reason: reason, path: path}), do: {path, reason}
  defp error_reason(%{reason: reason}), do: reason
  defp error_reason(other), do: other

  defp restore(snapshot) do
    Enum.each(snapshot, fn
      {path, nil} -> File.rm(path)
      {path, content} -> File.write(path, content)
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
