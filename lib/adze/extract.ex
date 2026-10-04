defmodule Adze.Extract do
  @moduledoc """
  `extract` — cut a definition (plus its private closure) out of a module
  into a brand-new module file.

  Builds on `Adze.LsDeps.ls_extract/3` for the closure and on
  `Adze.Definition` for the logical-definition groups. Produces:

    * a new target file containing `defmodule TargetModule do ... end`
      with the closure definitions in original source order and a
      filtered subset of the source module's `alias`/`use`/`import`/
      `require` directives;
    * a modified source where the cut definitions are gone and an
      `alias TargetModule` line is inserted near the top of the source
      module's body.

  ## Args

      Adze.Extract.extract(source,
        definition: "bar/2",
        module: "MyApp.Bar",
        from_module: "MyApp.Source"   # optional disambiguator
      )

  ## Output

      {:ok, %{
        target_module: "MyApp.Bar",
        target_path: "lib/my_app/bar.ex",
        target_content: "...",
        new_source: "...",
        source_diff: "..."
      }}

  ## Behaviour notes (settled for v1)

    * **Target path is derived from `--module`** via `Macro.underscore/1`
      and prefixed with `lib/`. Override with `path:` or `mix_root:` for
      tests / non-standard projects.
    * **Target file must not exist.** Existing file → `{:error,
      {:target_exists, path}}`. Append-into-existing is deliberately
      deferred — surface the collision to the AI.
    * **Multi-module source files** require `from_module:` to
      disambiguate when the named def exists in more than one sibling
      `defmodule`.
    * **Directive policy:**
        * `alias` is mechanically filtered — copied only when the
          binding (last segment or `:as` name) is referenced in the
          closure AST.
        * `use` / `import` / `require` are **never** copied to the
          target. The tool can't know without macro expansion which
          (if any) the closure depends on, so the principled
          mechanical answer is to drop them. The compiler is louder
          when we're under-permissive (missing macro → compile error)
          than when we're over-permissive (extra `import` → silent),
          so the failure mode favors dropping. Every dropped
          directive comes back in `dropped_directives` as
          `%{kind:, line:, text:}` so the AI driver can decide which
          (if any) to add back to the target.
    * **Callers across the project are rewritten.** Qualified calls,
      pipes and captures of each moved public def (resolved through
      aliases) are retargeted from `Source.fun` to `Target.fun` at every
      arity the def is callable at, including default-argument
      arities. The edits come back in `caller_diffs`. Calls adze can't
      retarget — bare calls through `import Source` (refused, see
      below) and dynamic `apply/3` — are left for the compiler to
      surface.
    * **Private targets are promoted.** Extracting a `defp` (or
      `defmacrop` / `defguardp`) target moves it across a module
      boundary, so it *must* become public for its surviving callers
      in the source module to reach it. The tool flips the kind
      (`defp` → `def`, etc.) and prepends `@doc false` (unless the def
      already has a `@doc`) to record that it's public for structural
      reasons rather than as API. Closure helpers stay private — by
      construction all their callers move with them. Promotions are
      reported in `promoted` as `[{name, arity}]`.
    * **Shared private helpers are promoted in the source.** A `defp`
      the closure calls but that also has callers staying behind can't
      move, and the target can only reach it as `Source.helper(...)` if
      it's public. It's flipped to `def` + `@doc false` in the source and
      reported in `promoted_in_source`. Shared `defmacrop` / `defguardp`
      helpers are refused with `{:error, {:private_macro_referenced,
      %{definitions: [{kind, name, arity}], source: module}}}` — they'd
      also need a `require` in the target. Public `defmacro` /
      `defguard` helpers that stay in the source are refused the same
      way, for the same reason.
    * **Macros and guards that move are refused if anyone calls them.**
      A moved public `defmacro` / `defguard` can't be reached as
      `Target.m(x)` without `require Target`, which adze doesn't insert.
      If the source module or any other file calls it, extract returns
      `{:error, {:moved_macro_referenced, %{definitions:, source:,
      callers:}}}`. Uncalled macros move fine.
    * **Importers are refused.** Calls through `import Source` are bare
      (`inner(x)`) and can't be retargeted. If another file imports the
      source and the import could cover a moved def, extract returns
      `{:error, {:imported_by, %{definitions:, source:, files:}}}`.
      Literal `only:` / `except:` lists and `only: :macros | :functions`
      are honoured. `use Source` counts as an import whenever `Source`
      defines `__using__` (its effect can't be ruled out statically).
      A chained `use` is caught because the file containing the
      `import Source` / `use Source` node (even inside a `quote`) is
      itself flagged. Dynamic `only:`/`except:` values are treated as
      importing everything (a safe over-refusal).

      **Known gap:** an import whose module is only known at runtime
      (`import unquote(mod)` in a `__using__`, with `use Base, Source`
      at the call site) never mentions `Source` literally and isn't
      seen. Extraction goes through and the bare call fails to compile.

  ## `extract!` writes both files

      Adze.Extract.extract!("lib/source.ex",
        definition: "bar/2",
        module: "MyApp.Bar"
      )

  Returns the same shape as `extract/2`, plus the side effects of
  writing `lib/my_app/bar.ex` (new) and rewriting `lib/source.ex`.
  """

  alias Adze.AST
  alias Adze.Definition
  alias Adze.Deps
  alias Adze.Extract.{Callers, Promote, Render, Source, Target}
  alias Adze.LsDeps
  alias Adze.ProjectRewrite
  alias Adze.Types
  alias Mix.Tasks.Format

  # This module resolves the definition and its closure and runs the
  # checks; the work is split across:
  #
  #   * `Adze.Extract.Target`     — renders the new module's file;
  #   * `Adze.Extract.Source`     — cuts the closure out of the source and
  #     qualifies its surviving local callers;
  #   * `Adze.Extract.Callers`    — retargets call sites in other files
  #     and refuses what that can't handle;
  #   * `Adze.Extract.LocalCalls` — the bare-call qualifier both files use;
  #   * `Adze.Extract.Promote` / `Adze.Extract.Render` — shared helpers.

  @directive_kinds [:alias, :use, :import, :require]

  @type opts :: [
          definition: Definition.definition_spec(),
          module: String.t(),
          from_module: String.t() | nil,
          path: Path.t() | nil,
          mix_root: Path.t() | nil,
          include_attrs: [atom()],
          files: %{Path.t() => String.t()},
          app_name: atom()
        ]

  @type dropped_directive :: %{
          kind: :use | :import | :require,
          line: pos_integer(),
          text: String.t()
        }

  @type result :: %{
          target_module: String.t(),
          target_path: Path.t(),
          target_content: String.t(),
          new_source: String.t(),
          source_diff: String.t(),
          source_module: String.t(),
          public_closure_keys: [{atom(), non_neg_integer()}],
          call_site_arities: %{{atom(), non_neg_integer()} => [non_neg_integer()]},
          caller_diffs: %{Path.t() => String.t()},
          dropped_directives: [dropped_directive()],
          promoted: [{atom(), non_neg_integer()}],
          promoted_in_source: [{atom(), non_neg_integer()}],
          moved_macro_keys: [{atom(), atom(), non_neg_integer()}],
          public_closure_classes: %{{atom(), non_neg_integer()} => :macro | :function}
        }

  @spec extract(String.t(), opts()) :: {:ok, result()} | {:error, term()}
  def extract(source, opts) when is_binary(source) and is_list(opts) do
    with {:ok, def_spec_raw} <- fetch_opt(opts, :definition),
         {:ok, parsed_key} <- Definition.parse_definition_spec(def_spec_raw),
         {:ok, target_module} <- fetch_opt(opts, :module),
         :ok <- validate_module_name(target_module),
         {:ok, target_path} <- resolve_target_path(target_module, opts),
         :ok <- check_target_path_free(target_path),
         {:ok, all_defs} <- Definition.list(source, Keyword.put(opts, :lenient, true)),
         def_key = Definition.resolve_key(parsed_key, all_defs),
         {:ok, source_module} <- resolve_source_module(all_defs, def_key, opts),
         :ok <- ensure_supported_source_module(source_module),
         {:ok, ast} <- parse(source),
         {:ok, body_info} <- collect_body_info(ast, source_module),
         {:ok, closure_defs} <- compute_closure(source, def_key, source_module, all_defs, opts),
         {:ok, shared_privates} <-
           shared_private_helpers(source, closure_defs, source_module, all_defs, opts),
         :ok <- check_moved_macros_unused(source, closure_defs, source_module, opts),
         :ok <- check_not_ambiguous(closure_defs ++ shared_privates) do
      {kept_directives, dropped_directives_raw} =
        filter_directives(body_info.directives, closure_defs)

      dropped_directives = render_dropped_directives(dropped_directives_raw, source)
      type_index = Types.index(body_info.body_nodes)
      formatter_opts = Keyword.get(opts, :formatter_opts, [])

      # The target def is the new module's entry point. If it was
      # private it has to become public; flip the AST kind here so the
      # AST-render path picks it up, and record the key so the
      # slice-render path and the caller-rewrite pass do too.
      {closure_defs, promoted} = Promote.promote_target(closure_defs, def_key)
      promoted_keys = MapSet.new(promoted)

      closure_keys_all = MapSet.new(closure_defs, &{&1.name, &1.arity})
      promoted_in_source = Enum.map(shared_privates, &{&1.name, &1.arity})

      # Default arguments make a def callable at several arities, so a
      # bare `entry(:x)` still refers to `entry/2` and must be qualified.
      source_remaining_keys =
        all_defs
        |> Enum.filter(&(&1.module == source_module))
        |> Enum.reject(&MapSet.member?(closure_keys_all, {&1.name, &1.arity}))
        |> Definition.callable_keys()

      try do
        target_content =
          Target.build_target_file(source, closure_defs, %{
            target_module: target_module,
            source_module: source_module,
            directives: kept_directives,
            type_index: type_index,
            source_remaining_keys: source_remaining_keys,
            promoted_keys: promoted_keys,
            formatter_opts: formatter_opts
          })

        needs_alias? =
          Source.target_needs_alias_in_source?(source, def_key, source_module, closure_defs, opts)

        new_source =
          Source.build_new_source(source, closure_defs, %{
            target_module: target_module,
            source_module: source_module,
            body_info: body_info,
            needs_alias?: needs_alias?,
            all_defs: all_defs,
            promote_keys: MapSet.new(promoted_in_source),
            formatter_opts: formatter_opts
          })

        # Keys whose call sites may need rewriting. Promoted defs are
        # public *now* (in the target) but had no cross-file callers
        # (they were private) — harmless to include in the project-wide
        # rename, and required for the in-file rewrite below.
        public_closure_keys =
          closure_defs
          |> Enum.filter(&(&1.visibility == :public))
          |> Enum.map(&{&1.name, &1.arity})

        # Default arguments make one definition callable at several
        # arities; callers at any of them must be rewritten.
        call_site_arities =
          closure_defs
          |> Enum.filter(&(&1.visibility == :public))
          |> Map.new(&{{&1.name, &1.arity}, Definition.callable_arities(&1)})

        {:ok,
         %{
           target_module: target_module,
           target_path: target_path,
           target_content: target_content,
           new_source: new_source,
           source_diff: Adze.Diff.unified(source, new_source),
           source_module: source_module,
           public_closure_keys: public_closure_keys,
           call_site_arities: call_site_arities,
           caller_diffs: %{},
           dropped_directives: dropped_directives,
           promoted: promoted,
           promoted_in_source: promoted_in_source,
           public_closure_classes:
             closure_defs
             |> Enum.filter(&(&1.visibility == :public))
             |> Map.new(
               &{{&1.name, &1.arity},
                if(&1.kind in [:defmacro, :defguard], do: :macro, else: :function)}
             ),
           moved_macro_keys: Enum.map(moved_macros(closure_defs), &{&1.kind, &1.name, &1.arity})
         }}
      catch
        {:typep_referenced, info} -> {:error, {:typep_referenced, info}}
        {:format, exception} -> {:error, {:format, exception}}
        {:render, exception} -> {:error, {:render, exception}}
      end
    end
  end

  @spec extract_file(Path.t(), opts()) :: {:ok, result()} | {:error, term()}
  def extract_file(path, opts) when is_binary(path) do
    with {:ok, result, _rewrite} <- prepare(path, opts), do: {:ok, result}
  end

  @spec extract!(Path.t(), opts()) :: {:ok, result()} | {:error, term()}
  def extract!(path, opts) when is_binary(path) do
    with {:ok, result, rewrite} <- prepare(path, opts),
         :ok <- ProjectRewrite.write(rewrite) do
      {:ok, result}
    end
  end

  # Single pipeline shared by extract_file/2 (dry-run) and extract!/2
  # (write). The order is load-bearing:
  #
  #   1. read the source — from disk or the in-memory `files:` map;
  #   2. run extract/2 to produce target_content + new_source;
  #   3. build a ProjectRewrite, inject new_source as the source file's
  #      content, create the new target file;
  #   4. run rename_function for every public closure def so external
  #      callers across the project get their `SourceModule.target(...)`
  #      (and pipe / capture variants) rewritten to `TargetModule.target(...)`.
  #      Igniter's def-move step is a no-op here because step 2 already
  #      removed the def from `new_source`; only call-site rewrites land.
  #
  # `extract!/2` then flushes the rewrite. `extract_file/2` discards it.
  defp prepare(path, opts) do
    opts = Keyword.put_new_lazy(opts, :formatter_opts, fn -> resolve_formatter_opts(path) end)

    with {:ok, source} <- read_source(path, opts),
         {:ok, single} <- extract(source, opts),
         {:ok, rewrite, caller_diffs} <- Callers.run_project_rewrite(path, single, opts),
         :ok <- Callers.check_moved_macros_external(single, caller_diffs),
         :ok <- Callers.check_importers(rewrite, single, path) do
      {:ok, Map.put(single, :caller_diffs, caller_diffs), rewrite}
    end
  end

  # `Mix.Tasks.Format.formatter_for_file/1` reads a project's
  # `.formatter.exs` and returns `{formatter_fn, opts}` with
  # `:import_deps` expanded into a merged `:locals_without_parens`.
  # We only need the opts. A failed lookup (no `.formatter.exs`,
  # parse error, …) is non-fatal — return `[]` and let the formatter
  # use its defaults.
  defp resolve_formatter_opts(path) do
    if Code.ensure_loaded?(Format) and function_exported?(Format, :formatter_for_file, 1) do
      try do
        {_formatter, opts} = Format.formatter_for_file(path)
        opts
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp read_source(path, opts) do
    case Keyword.get(opts, :files) do
      nil ->
        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:file_read, reason}}
        end

      files when is_map(files) ->
        case Map.fetch(files, path) do
          {:ok, content} -> {:ok, content}
          :error -> {:error, {:file_read, :enoent}}
        end
    end
  end

  # --- closure checks: shared private helpers, moved macros ---------------

  # Private definitions that stay in the source module but are called
  # from the extracted closure. The target reaches them as
  # `SourceModule.name(...)`, which only compiles if they're public.
  #
  # Plain `defp` helpers are promoted in place (`def` + `@doc false`),
  # mirroring how a private target is promoted. Private macros and
  # guards are refused instead: making them public isn't enough — the
  # target would also need `require SourceModule`, and a guard may be
  # used inside a `when` clause. Leave that decision to the user.
  # Public macros/guards staying in the source are refused for the same
  # reason: the target would call `SourceModule.m(x)` with no `require`.
  defp shared_private_helpers(source, closure_defs, source_module, all_defs, opts) do
    closure_keys = MapSet.new(closure_defs, &{&1.name, &1.arity})

    with {:ok, %{modules: modules}} <- Deps.deps(source, opts),
         %{defs: dep_defs} <- Enum.find(modules, &(&1.name == source_module)) do
      called =
        dep_defs
        |> Enum.filter(&MapSet.member?(closure_keys, {&1.name, &1.arity}))
        |> Enum.flat_map(& &1.calls)
        |> MapSet.new()

      shared =
        all_defs
        |> Enum.filter(fn d ->
          d.module == source_module and
            (d.visibility == :private or d.kind in [:defmacro, :defguard]) and
            not MapSet.member?(closure_keys, {d.name, d.arity}) and
            MapSet.member?(called, {d.name, d.arity})
        end)
        |> Enum.sort_by(&def_sort_key/1)

      case Enum.reject(shared, &(&1.kind == :defp)) do
        [] ->
          {:ok, shared}

        unpromotable ->
          {:error,
           {:private_macro_referenced,
            %{
              definitions: Enum.map(unpromotable, &{&1.kind, &1.name, &1.arity}),
              source: source_module
            }}}
      end
    else
      # Couldn't analyze — fall through without promotion; the compiler
      # will still flag any private remote call.
      _ -> {:ok, []}
    end
  end

  # A public macro/guard that moves to the target can't be called as
  # `Target.m(x)` without `require Target` at each call site, and adze
  # doesn't insert that. Refuse when the source module still calls one.
  defp moved_macros(closure_defs) do
    for d <- closure_defs, d.visibility == :public, d.kind in [:defmacro, :defguard], do: d
  end

  defp check_moved_macros_unused(source, closure_defs, source_module, opts) do
    case moved_macros(closure_defs) do
      [] ->
        :ok

      macros ->
        closure_keys = MapSet.new(closure_defs, &{&1.name, &1.arity})

        with {:ok, %{modules: modules}} <- Deps.deps(source, opts),
             %{defs: dep_defs} <- Enum.find(modules, &(&1.name == source_module)) do
          remaining_calls =
            dep_defs
            |> Enum.reject(&MapSet.member?(closure_keys, {&1.name, &1.arity}))
            |> Enum.flat_map(& &1.calls)
            |> MapSet.new()

          case Enum.filter(macros, &MapSet.member?(remaining_calls, {&1.name, &1.arity})) do
            [] -> :ok
            used -> {:error, moved_macro_error(used, source_module)}
          end
        else
          _ -> :ok
        end
    end
  end

  defp moved_macro_error(used, source_module) do
    {:moved_macro_referenced,
     %{
       definitions: Enum.map(used, &{&1.kind, &1.name, &1.arity}),
       source: source_module,
       callers: [source_module]
     }}
  end

  # --- option / arg handling ---------------------------------------------

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, v} when is_binary(v) and v != "" -> {:ok, v}
      {:ok, {n, a}} when is_atom(n) and is_integer(a) -> {:ok, {n, a}}
      {:ok, other} -> {:error, {:bad_opt, key, other}}
      :error -> {:error, {:missing_opt, key}}
    end
  end

  defp validate_module_name(name) do
    if Adze.Names.valid_module_name?(name) do
      :ok
    else
      {:error, {:bad_module_name, name}}
    end
  end

  defp resolve_target_path(target_module, opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) ->
        {:ok, path}

      nil ->
        rel = Path.join("lib", Macro.underscore(target_module) <> ".ex")

        case Keyword.get(opts, :mix_root) do
          nil -> {:ok, rel}
          root -> {:ok, Path.join(root, rel)}
        end
    end
  end

  defp check_target_path_free(path) do
    if File.exists?(path), do: {:error, {:target_exists, path}}, else: :ok
  end

  defp parse(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, reason} -> {:error, {:parse, reason}}
    end
  end

  # --- source-module resolution ------------------------------------------

  # Callers are found and rewritten by module name, which only works for a
  # `Foo.Bar` module. For anything else (`defmodule :erl_mod`, a dynamic
  # name) callers in other files would be left calling a removed
  # function, and the in-file rewrite can't name the source module either.
  defp ensure_supported_source_module(module) do
    if Adze.Names.valid_module_name?(module),
      do: :ok,
      else: {:error, {:unsupported_module, module}}
  end

  defp resolve_source_module(all_defs, def_key, opts) do
    case Definition.pick(def_key, all_defs, Keyword.get(opts, :from_module)) do
      {:ok, %Definition{module: module}} -> {:ok, module}
      {:error, :not_found} -> {:error, {:not_found, def_key}}
      {:error, _} = err -> err
    end
  end

  defp compute_closure(source, def_key, source_module, all_defs, opts) do
    case LsDeps.ls_extract(source, def_key, opts) do
      {:ok, %{modules: modules}} ->
        case Enum.find(modules, &(&1.name == source_module)) do
          nil ->
            {:error, {:not_found, def_key}}

          %{closure: closure_entries} ->
            keys = MapSet.new(closure_entries, &{&1.name, &1.arity})

            defs =
              all_defs
              |> Enum.filter(fn d ->
                d.module == source_module and MapSet.member?(keys, {d.name, d.arity})
              end)
              |> Enum.sort_by(&def_sort_key/1)

            {:ok, defs}
        end

      err ->
        err
    end
  end

  defp check_not_ambiguous(defs) do
    case Enum.find(defs, & &1.ambiguous) do
      nil -> :ok
      %Definition{ambiguous: info} -> {:error, {:ambiguous_attribute, info}}
    end
  end

  defp def_sort_key(%Definition{range: %{start: s}, name: n, arity: a}) do
    {Keyword.fetch!(s, :line), Keyword.fetch!(s, :column), n, a}
  end

  defp def_sort_key(%Definition{name: n, arity: a}), do: {0, 0, n, a}

  # --- source-body inspection --------------------------------------------
  #
  # We need:
  #   - the source defmodule's opening line range (to know where the body
  #     starts, for alias insertion);
  #   - every alias / use / import / require AST node in the body, with
  #     its line range.

  defp collect_body_info(ast, source_module) do
    case AST.find_module(ast, source_module) do
      nil ->
        {:error, {:source_module_not_found, source_module}}

      {defmod_node, body_block} ->
        defmod_range = Sourceror.get_range(defmod_node)
        body_nodes = AST.body_exprs(body_block)
        directives = Enum.filter(body_nodes, &directive?/1)
        moduledoc_nodes = Enum.filter(body_nodes, &moduledoc?/1)

        {:ok,
         %{
           defmod_open_line: Keyword.fetch!(defmod_range.start, :line),
           directives: directives,
           moduledoc_nodes: moduledoc_nodes,
           body_nodes: body_nodes
         }}
    end
  end

  defp directive?({kind, _, args}) when kind in @directive_kinds and is_list(args), do: true
  defp directive?(_), do: false

  defp moduledoc?({:@, _, [{:moduledoc, _, _}]}), do: true
  defp moduledoc?(_), do: false

  # --- directive filtering -----------------------------------------------
  #
  # Two classes:
  #
  #   * `alias` — bindings are statically resolvable, so we mechanically
  #     filter: kept iff the closure references the binding (last
  #     segment of the alias path, or the `:as` name). Mechanical
  #     enough that the tool can decide; no notice surfaced for
  #     filtered-out aliases.
  #
  #   * `use` / `import` / `require` — what they inject can't be
  #     decided without macro expansion, so we don't guess. They're
  #     never copied to the target. Instead, each is surfaced as a
  #     `:dropped_directive` notice so the AI driver can read the
  #     dry-run, see what was in the source's header, and decide
  #     whether to add it back to the target.
  #     The compiler is louder when we're under-permissive (missing
  #     macro → compile error) than when we're over-permissive
  #     (extra `import` → silent), so under-permissive wins.
  defp filter_directives(directives, closure_defs) do
    used_bindings = collect_used_bindings(closure_defs)

    {kept_rev, dropped_rev} =
      Enum.reduce(directives, {[], []}, fn directive, {kept, dropped} ->
        case directive do
          {:alias, _, _} = node ->
            if alias_referenced?(node, used_bindings) do
              {[node | kept], dropped}
            else
              {kept, dropped}
            end

          {kind, _, _} = node when kind in [:use, :import, :require] ->
            {kept, [{kind, node} | dropped]}

          node ->
            {[node | kept], dropped}
        end
      end)

    {Enum.reverse(kept_rev), Enum.reverse(dropped_rev)}
  end

  # Render each dropped directive into {kind, line, text} so the
  # caller can show the source text of what was dropped. The line
  # number is the start line of the AST node in the source.
  defp render_dropped_directives(dropped_directives, source) do
    source_lines = String.split(source, "\n")

    dropped_directives
    |> Enum.map(fn {kind, node} ->
      case Sourceror.get_range(node) do
        nil ->
          nil

        range ->
          line = Keyword.fetch!(range.start, :line)
          text = range |> Render.slice_range_text(source_lines) |> String.trim()
          %{kind: kind, line: line, text: text}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp collect_used_bindings(closure_defs) do
    closure_defs
    |> Enum.flat_map(& &1.nodes)
    |> Enum.reduce(MapSet.new(), &collect_aliases_in/2)
  end

  defp collect_aliases_in(ast, acc) do
    {_ast, acc} =
      Macro.prewalk(ast, acc, fn node, a ->
        case node do
          {:__aliases__, _, [first | _]} when is_atom(first) ->
            {node, MapSet.put(a, first)}

          _ ->
            {node, a}
        end
      end)

    acc
  end

  # `alias Foo.Bar` → binding atom :Bar
  # `alias Foo.Bar, as: Baz` → binding atom :Baz
  # `alias Foo.{Bar, Baz}` → keep if *any* member binding referenced (v1)
  defp alias_referenced?({:alias, _, args}, used_bindings) do
    args
    |> AST.alias_bindings()
    |> Enum.any?(&MapSet.member?(used_bindings, &1))
  end
end
