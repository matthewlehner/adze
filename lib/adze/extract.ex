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

  alias Adze.Definition
  alias Adze.Deps
  alias Adze.LsDeps
  alias Adze.ProjectRewrite
  alias Adze.Types

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
      {closure_defs, promoted} = promote_target(closure_defs, def_key)
      promoted_keys = MapSet.new(promoted)

      closure_keys_all = MapSet.new(closure_defs, &{&1.name, &1.arity})
      promoted_in_source = Enum.map(shared_privates, &{&1.name, &1.arity})

      # Default arguments make a def callable at several arities, so a
      # bare `entry(:x)` still refers to `entry/2` and must be qualified.
      source_remaining_keys =
        all_defs
        |> Enum.filter(&(&1.module == source_module))
        |> Enum.reject(&MapSet.member?(closure_keys_all, {&1.name, &1.arity}))
        |> callable_keys()

      try do
        target_content =
          build_target_file(
            target_module,
            kept_directives,
            source,
            closure_defs,
            type_index,
            source_module,
            source_remaining_keys,
            promoted_keys,
            formatter_opts
          )

        needs_alias? =
          target_needs_alias_in_source?(source, def_key, source_module, closure_defs, opts)

        new_source =
          build_new_source(
            source,
            body_info,
            closure_defs,
            target_module,
            needs_alias?,
            all_defs,
            source_module,
            MapSet.new(promoted_in_source),
            formatter_opts
          )

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
         {:ok, rewrite, caller_diffs} <- run_project_rewrite(path, single, opts),
         :ok <- check_moved_macros_external(single, caller_diffs),
         :ok <- check_importers(rewrite, single, path) do
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
    if Code.ensure_loaded?(Mix.Tasks.Format) and
         function_exported?(Mix.Tasks.Format, :formatter_for_file, 1) do
      try do
        {_formatter, opts} = Mix.Tasks.Format.formatter_for_file(path)
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

  defp run_project_rewrite(source_path, single, opts) do
    rewrite_opts = Keyword.take(opts, [:mix_root, :files, :app_name])

    with {:ok, rewrite} <- ProjectRewrite.new(rewrite_opts),
         {:ok, rewrite} <- ProjectRewrite.put_content(rewrite, source_path, single.new_source),
         {:ok, rewrite} <-
           ProjectRewrite.create_file(rewrite, single.target_path, single.target_content),
         {:ok, rewrite} <- apply_call_site_rewrites(rewrite, single),
         {:ok, dry} <- ProjectRewrite.result(rewrite) do
      caller_diffs = strip_local_paths(dry.diffs, source_path, single.target_path, rewrite)
      {:ok, rewrite, caller_diffs}
    end
  end

  defp apply_call_site_rewrites(rewrite, single) do
    source_mod = string_to_module(single.source_module)
    target_mod = string_to_module(single.target_module)

    # Igniter matches the written arity, so `v |> S.foo(2)` (really
    # foo/2) would be taken for foo/1. Shield those calls first.
    allowed =
      Enum.reduce(single.public_closure_keys, %{}, fn {name, arity} = key, acc ->
        arities = Map.get(single.call_site_arities, key, [arity])
        Map.update(acc, name, arities, &Enum.uniq(&1 ++ arities))
      end)

    rewrite = ProjectRewrite.protect_piped_calls(rewrite, allowed)

    rewrite =
      Enum.reduce(single.public_closure_keys, rewrite, fn {name, arity} = key, rw ->
        arities = Map.get(single.call_site_arities, key, [arity])

        {:ok, rw} =
          ProjectRewrite.rename_function(rw, {source_mod, name}, {target_mod, name},
            arity: arities
          )

        rw
      end)

    {:ok, ProjectRewrite.unprotect_calls(rewrite)}
  end

  defp string_to_module(str) when is_binary(str), do: Module.concat(String.split(str, "."))

  # --- private-target promotion -------------------------------------------

  @promotions %{defp: :def, defmacrop: :defmacro, defguardp: :defguard}

  # Flip the target definition to its public kind when it's private.
  # Returns the updated closure list and the list of promoted keys
  # (empty or a single element — only the target can be promoted).
  defp promote_target(closure_defs, {name, arity}) do
    Enum.map_reduce(closure_defs, [], fn
      %Definition{name: ^name, arity: ^arity, visibility: :private, kind: kind} = d, acc
      when is_map_key(@promotions, kind) ->
        {promote_definition(d), [{name, arity} | acc]}

      d, acc ->
        {d, acc}
    end)
  end

  # Flip a private definition's AST kind (`defp` → `def`, etc.).
  defp promote_definition(%Definition{kind: kind} = d) do
    new_kind = Map.fetch!(@promotions, kind)

    flip = fn
      {^kind, m, args} -> {new_kind, m, args}
      other -> other
    end

    %{
      d
      | kind: new_kind,
        visibility: :public,
        nodes: Enum.map(d.nodes, flip),
        parts: %{d.parts | clauses: Enum.map(d.parts.clauses, flip)}
    }
  end

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

  # Cross-file callers: any caller diff means a call site was rewritten
  # to `Target.m(x)` without a `require`.
  defp check_moved_macros_external(single, caller_diffs) do
    macro_keys = single.moved_macro_keys

    if macro_keys != [] and caller_diffs != %{} do
      {:error,
       {:moved_macro_referenced,
        %{definitions: macro_keys, source: single.source_module, callers: Map.keys(caller_diffs)}}}
    else
      :ok
    end
  end

  # `import Source` callers use bare calls, which the rewrite can't
  # retarget — the moved def would silently become undefined there.
  defp check_importers(rewrite, single, source_path) do
    kinds = single.public_closure_classes

    keys =
      Enum.map(single.public_closure_keys, fn {n, a} ->
        {n, a, Map.get(kinds, {n, a}, :function)}
      end)

    case ProjectRewrite.importers(
           rewrite,
           single.source_module,
           keys,
           [source_path, single.target_path],
           use_imports?: uses_inject_import?(single.new_source)
         ) do
      [] ->
        :ok

      files ->
        {:error,
         {:imported_by,
          %{
            definitions: single.public_closure_keys,
            source: single.source_module,
            files: Enum.sort(files)
          }}}
    end
  end

  # Does the source define `__using__`? Whatever it does (inline
  # `import`, a helper call, ...) can't be ruled out statically, so
  # `use Source` elsewhere is treated as importing the source's defs.
  defp uses_inject_import?(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        {_, found} =
          Macro.prewalk(ast, false, fn
            {:defmacro, _, [{:__using__, _, _} | _]} = node, _ -> {node, true}
            node, acc -> {node, acc}
          end)

        found

      _ ->
        false
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

  # The slice-render path copies source text verbatim, so the private
  # keyword survives there. Flip it on exactly the clause start lines
  # (mirrors Adze.ExtractPrivate.flip_clauses/3 in the other direction)
  # rather than regexing the whole block — a `defp` inside a `quote`
  # body must be left alone.
  defp flip_private_keyword_in_text(text, %Definition{} = d) do
    first_line = Keyword.fetch!(d.range.start, :line)

    clause_offsets =
      d.parts.clauses
      |> Enum.map(fn clause ->
        case Sourceror.get_range(clause) do
          %{start: s} -> Keyword.get(s, :line) - first_line
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    pattern = ~r/^(\s*)(defp|defmacrop|defguardp)(\s)/

    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      if MapSet.member?(clause_offsets, idx) do
        Regex.replace(pattern, line, fn _, indent, kw, ws ->
          indent <> Atom.to_string(Map.fetch!(@promotions, String.to_atom(kw))) <> ws
        end)
      else
        line
      end
    end)
    |> Enum.join("\n")
  end

  # `@doc false` marks the promoted def as public-for-structure, not
  # API. Skip when the author already wrote a `@doc` (true, false, or
  # a docstring) — theirs wins.
  defp prepend_doc_false(text, %Definition{parts: %{attributes: attrs}}) do
    if Enum.any?(attrs, fn {attr_name, _} -> attr_name == :doc end) do
      text
    else
      indent =
        case Regex.run(~r/^(\s*)\S/, text) do
          [_, i] -> i
          _ -> ""
        end

      # Insert below any leading comment lines so the comment stays
      # attached to the `@doc` / def it describes.
      {comments, rest} =
        text
        |> String.split("\n")
        |> Enum.split_while(&String.starts_with?(String.trim_leading(&1), "#"))

      Enum.join(comments ++ [indent <> "@doc false" | rest], "\n")
    end
  end

  # The diffs map from ProjectRewrite.result/1 keys every changed file —
  # including the source (its in-file edit is already in source_diff)
  # and the brand-new target (its content is already in target_content).
  # Strip both so caller_diffs is exactly the cross-file callers.
  defp strip_local_paths(diffs, source_path, target_path, rewrite) do
    keys_to_drop =
      [source_path, target_path]
      |> Enum.flat_map(&path_aliases(&1, rewrite))
      |> Enum.uniq()

    Map.drop(diffs, keys_to_drop)
  end

  defp path_aliases(path, %ProjectRewrite{root: nil}) do
    # Test mode: paths are relative-to-cwd. `Path.join(".", "lib/...")`
    # leaves a leading `./`; Igniter strips it. Normalize both sides.
    [path, strip_dot_prefix(path)] |> Enum.uniq()
  end

  defp path_aliases(path, %ProjectRewrite{root: root}) do
    expanded = Path.expand(path)
    rel = Path.relative_to(expanded, Path.expand(root))
    [path, expanded, rel, strip_dot_prefix(path)] |> Enum.uniq()
  end

  defp strip_dot_prefix("./" <> rest), do: rest
  defp strip_dot_prefix(p), do: p

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
        root = Keyword.get(opts, :mix_root, ".")
        rel = Path.join("lib", Macro.underscore(target_module) <> ".ex")
        {:ok, Path.join(root, rel)}
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

  defp resolve_source_module(all_defs, {name, arity}, opts) do
    matches =
      all_defs
      |> Enum.filter(&(&1.name == name and &1.arity == arity))
      |> Enum.map(& &1.module)
      |> Enum.uniq()

    case {Keyword.get(opts, :from_module), matches} do
      {nil, []} ->
        {:error, {:not_found, {name, arity}}}

      {nil, [m]} ->
        {:ok, m}

      {nil, mods} ->
        {:error, {:ambiguous_source_module, %{definition: {name, arity}, modules: mods}}}

      {from, mods} ->
        if from in mods do
          {:ok, from}
        else
          {:error, {:from_module_mismatch, %{from: from, candidates: mods}}}
        end
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
    case find_defmodule(ast, "", source_module) do
      nil ->
        {:error, {:source_module_not_found, source_module}}

      {body_block, defmod_range} ->
        body_nodes = body_to_list(body_block)
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

  defp find_defmodule({:__block__, _, exprs}, prefix, target) do
    Enum.find_value(exprs, &find_defmodule(&1, prefix, target))
  end

  defp find_defmodule({:defmodule, _meta, [alias_ast, [{_do, body}]]} = node, prefix, target) do
    name = Adze.Names.defmodule_name(alias_ast, prefix)

    cond do
      name == target ->
        {body, Sourceror.get_range(node)}

      String.starts_with?(target, name <> ".") ->
        find_defmodule(body, name, target)

      true ->
        nil
    end
  end

  defp find_defmodule(_other, _prefix, _target), do: nil

  defp body_to_list({:__block__, _, exprs}), do: exprs
  defp body_to_list(single), do: [single]

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
          text = range |> slice_range_text(source_lines) |> String.trim()
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
    |> alias_bindings()
    |> Enum.any?(&MapSet.member?(used_bindings, &1))
  end

  defp alias_bindings([{:__aliases__, _, parts} | rest]) do
    case find_as_value(rest) do
      {:__aliases__, _, [as_atom]} -> [as_atom]
      _ -> [List.last(parts)]
    end
  end

  defp alias_bindings([
         {{:., _, [{:__aliases__, _, _prefix}, :{}]}, _, members}
       ]) do
    Enum.flat_map(members, fn
      {:__aliases__, _, parts} -> [List.last(parts)]
      _ -> []
    end)
  end

  defp alias_bindings(_), do: []

  # Sourceror wraps keyword-list keys in `{:__block__, _, [:key]}`, so we
  # can't use Keyword.get directly. Walk pairs and unwrap each key.
  defp find_as_value([opts]) when is_list(opts) do
    Enum.find_value(opts, fn
      {key, value} -> if unwrap_atom(key) == :as, do: value, else: nil
      _ -> nil
    end)
  end

  defp find_as_value(_), do: nil

  defp unwrap_atom({:__block__, _, [a]}) when is_atom(a), do: a
  defp unwrap_atom(a) when is_atom(a), do: a
  defp unwrap_atom(_), do: nil

  # --- target file construction ------------------------------------------

  defp build_target_file(
         target_module,
         directives,
         source,
         closure_defs,
         type_index,
         source_module,
         source_remaining_keys,
         promoted_keys,
         formatter_opts
       ) do
    source_lines = String.split(source, "\n")

    directive_blocks =
      directives
      |> Enum.map(&slice_node_text(&1, source_lines))
      |> Enum.reject(&(&1 == ""))

    closure_blocks =
      Enum.map(closure_defs, fn d ->
        rendered =
          render_closure_def(d, source_lines, type_index, source_module, source_remaining_keys)

        if MapSet.member?(promoted_keys, {d.name, d.arity}) do
          rendered
          |> flip_private_keyword_in_text(d)
          |> prepend_doc_false(d)
        else
          rendered
        end
      end)

    # Join directives with a single \n so the formatter keeps them as one
    # block. The directive cluster and the closure cluster are separated
    # by a blank line.
    directive_group = Enum.join(directive_blocks, "\n")
    closure_group = Enum.join(closure_blocks, "\n\n")

    body =
      [directive_group, closure_group]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    raw = "defmodule #{target_module} do\n#{body}\nend\n"
    reformat(raw, formatter_opts)
  end

  # If the def has a typespec attribute referencing a local type, render
  # the whole group from AST (with type calls qualified). Same for bodies
  # containing `__MODULE__` (rewrite-to-source-alias). For bodies calling
  # source-module-local functions that aren't being extracted (qualify
  # the bare call to `SourceModule.fn(...)`), try the rewrite and only
  # fall back to slicing if nothing matched — the walker reports whether
  # it changed anything, so we don't need a separate detection pass.
  # Otherwise slice from source — that preserves exotic formatting /
  # comments verbatim.
  defp render_closure_def(
         definition,
         source_lines,
         type_index,
         source_module,
         source_remaining_keys
       ) do
    cond do
      needs_type_qualification?(definition, type_index) or
          references_module_macro?(definition.nodes) ->
        render_def_ast(definition, type_index, source_module, source_remaining_keys)

      map_size(source_remaining_keys) > 0 ->
        case try_rewrite_source_local(definition, source_module, source_remaining_keys) do
          {:changed, rendered} -> rendered
          :unchanged -> slice_range_text(definition.range, source_lines)
        end

      true ->
        slice_range_text(definition.range, source_lines)
    end
  end

  # We re-use the rewriting walker as our detector — if it rewrote anything,
  # render the modified AST; if not, the caller falls back to source slicing.
  defp try_rewrite_source_local(definition, source_module, source_remaining_keys) do
    source_parts = source_module |> String.split(".") |> Enum.map(&String.to_atom/1)

    {new_nodes, any_changed?} =
      Enum.map_reduce(definition.nodes, false, fn node, acc ->
        {new_node, changed?} =
          rewrite_def_body(node, source_remaining_keys, source_parts)

        {new_node, acc or changed?}
      end)

    if any_changed? do
      {:changed, new_nodes |> Enum.map(&render_node/1) |> Enum.join("\n")}
    else
      :unchanged
    end
  end

  defp needs_type_qualification?(_definition, type_index) when map_size(type_index) == 0,
    do: false

  defp needs_type_qualification?(definition, type_index) do
    Enum.any?(definition.nodes, fn
      {:@, _, [{kind, _, _}]} = node when kind in [:spec, :callback, :macrocallback] ->
        Types.references_local?(node, type_index)

      _ ->
        false
    end)
  end

  # `__MODULE__` inside a def body resolves to the enclosing module at
  # compile time. After extraction the enclosing module *is* the new
  # target — so `%__MODULE__{}` struct matches and any other `__MODULE__`
  # reference would silently resolve to the target. That's wrong when
  # the struct (or the thing being referenced) lives on the source
  # module — Ecto schemas, GenServer state structs, etc. When we see
  # `__MODULE__` anywhere in the definition, force AST rendering and
  # rewrite each occurrence to the source module's aliased form.
  defp references_module_macro?(nodes) do
    Enum.any?(nodes, fn node ->
      {_node, found?} =
        Macro.prewalk(node, false, fn
          {:__MODULE__, _, _} = n, _ -> {n, true}
          n, acc -> {n, acc}
        end)

      found?
    end)
  end

  defp render_def_ast(definition, type_index, source_module, source_remaining_keys) do
    source_parts = source_module |> String.split(".") |> Enum.map(&String.to_atom/1)

    definition.nodes
    |> Enum.map(fn
      {:@, _, [{kind, _, _}]} = node when kind in [:spec, :callback, :macrocallback] ->
        node
        |> Types.qualify(type_index, source_module)
        |> rewrite_module_macro(source_module)
        |> render_node()

      node ->
        node
        |> rewrite_module_macro(source_module)
        |> rewrite_def_body(source_remaining_keys, source_parts)
        |> elem(0)
        |> render_node()
    end)
    |> Enum.join("\n")
  end

  defp rewrite_module_macro(node, source_module) do
    parts = source_module |> String.split(".") |> Enum.map(&String.to_atom/1)

    Macro.prewalk(node, fn
      {:__MODULE__, meta, _ctx} -> {:__aliases__, meta, parts}
      n -> n
    end)
  end

  # Skip Sourceror's automatic Mix.Tasks.Format lookup by passing
  # an explicit empty list. Code.format_string! runs afterward with
  # the project's resolved formatter opts (see resolve_formatter_opts/1)
  # and normalizes the result.
  defp render_node(node) do
    Sourceror.to_string(node, locals_without_parens: [])
  rescue
    e -> throw({:render, e})
  end

  defp slice_node_text(node, source_lines) do
    case Sourceror.get_range(node) do
      nil -> ""
      range -> slice_range_text(range, source_lines)
    end
  end

  defp slice_range_text(%{start: s, end: e}, source_lines) do
    start_line = Keyword.fetch!(s, :line) - 1
    end_line = Keyword.fetch!(e, :line) - 1

    source_lines
    |> Enum.slice(start_line..end_line)
    |> Enum.join("\n")
  end

  # --- new source construction -------------------------------------------
  #
  # Three classes of line-range operations on the original source, all
  # applied in reverse start-line order so earlier offsets aren't shifted
  # by later edits:
  #
  #   1. CUT — every closure def's full line range is replaced with "".
  #      Same trailing-blank trick as Move so blank separators don't
  #      accumulate.
  #
  #   2. REWRITE — every surviving def in the source module whose body
  #      calls or captures an extracted name (`target(x)`, `&target/1`)
  #      gets re-rendered with those references rewritten to the target
  #      alias (`Target.target(x)`, `&Target.target/1`). Without this,
  #      the source no longer compiles after extract because bare local
  #      calls don't resolve cross-module.
  #
  #   3. ALIAS INSERT — when at least one surviving caller exists, an
  #      `alias TargetModule` line is appended after the last header
  #      node (`@moduledoc`, `use`, `import`, `alias`, `require`).
  #      Skipped when no caller survived (avoids `unused alias`
  #      warnings on public-API extractions).

  defp build_new_source(
         source,
         body_info,
         closure_defs,
         target_module,
         needs_alias?,
         all_defs,
         source_module,
         promote_keys,
         formatter_opts
       ) do
    lines = String.split(source, "\n")
    closure_keys = MapSet.new(closure_defs, &{&1.name, &1.arity})

    # Promoted defs already carry `visibility: :public` at this point
    # (see promote_target/2), so they're picked up here and their
    # surviving in-module callers get qualified against the target.
    rewrite_keys =
      closure_defs
      |> Enum.filter(&(&1.visibility == :public))
      |> callable_keys()

    {target_parts, add_alias?} = target_reference(body_info, target_module)

    cut_ops = build_cut_ops(closure_defs, lines)

    rewrite_ops =
      build_rewrite_ops(
        all_defs,
        source_module,
        closure_keys,
        rewrite_keys,
        target_parts,
        promote_keys,
        lines
      )

    alias_ops =
      if needs_alias? and add_alias?,
        do: [build_alias_op(body_info, target_module)],
        else: []

    ops =
      (cut_ops ++ rewrite_ops ++ alias_ops)
      |> Enum.sort_by(fn {s, _, _} -> -s end)

    final_lines = Enum.reduce(ops, lines, &apply_line_op/2)
    reformat(Enum.join(final_lines, "\n"), formatter_opts)
  end

  # Each op is {start_line_1idx, end_line_1idx, replacement_text}.
  # When end < start, it's an insertion at `start` (no lines replaced).
  # An empty replacement deletes the range.
  defp apply_line_op({s, e, text}, lines) when e < s do
    {pre, post} = Enum.split(lines, s - 1)
    pre ++ String.split(text, "\n") ++ post
  end

  defp apply_line_op({s, e, ""}, lines) do
    {pre, rest} = Enum.split(lines, s - 1)
    {_drop, post} = Enum.split(rest, e - s + 1)
    pre ++ post
  end

  defp apply_line_op({s, e, text}, lines) do
    {pre, rest} = Enum.split(lines, s - 1)
    {_drop, post} = Enum.split(rest, e - s + 1)
    pre ++ String.split(text, "\n") ++ post
  end

  defp build_cut_ops(closure_defs, lines) do
    Enum.map(closure_defs, fn d ->
      s = Keyword.fetch!(d.range.start, :line)
      e = Keyword.fetch!(d.range.end, :line)

      e2 =
        case Enum.at(lines, e) do
          nil -> e
          next -> if String.trim(next) == "", do: e + 1, else: e
        end

      {s, e2, ""}
    end)
  end

  # How surviving source code should spell the target module, and
  # whether an `alias TargetModule` must be inserted for that spelling.
  #
  #   * an existing `alias Target.Module` already binds the short name →
  #     reuse it, insert nothing;
  #   * the short name (last segment) is free in the source module →
  #     `[:Short]` + insert the alias;
  #   * the short name is already taken — another alias binds it
  #     (`alias Other.Helpers`, `as: Helpers`), a nested `defmodule`
  #     auto-aliases it, or code references a top-level module of that
  #     name → fully-qualify every reference and insert no alias.
  #     A second `alias X.Helpers` would silently re-point the existing
  #     `Helpers.go(x)` calls at the new module.
  #
  # The fully-qualified form gets an `Elixir.` prefix when its first
  # segment is itself shadowed by an alias in the source module.
  defp target_reference(body_info, target_module) do
    full = target_module |> String.split(".") |> Enum.map(&String.to_atom/1)
    short = List.last(full)
    {bindings, existing_targets} = alias_info(body_info.body_nodes)

    cond do
      MapSet.member?(existing_targets, full) ->
        {[short], false}

      not MapSet.member?(bindings, short) and
          not MapSet.member?(alias_heads(body_info.body_nodes), short) ->
        {[short], true}

      MapSet.member?(bindings, hd(full)) ->
        {[:"Elixir" | full], false}

      true ->
        {full, false}
    end
  end

  # Names bound by `alias` directives (anywhere in the module body,
  # including function-local aliases) and nested `defmodule`s, plus the
  # full module paths that are aliased under their own last segment.
  defp alias_info(body_nodes) do
    Enum.reduce(body_nodes, {MapSet.new(), MapSet.new()}, fn node, acc ->
      {_, acc} =
        Macro.prewalk(node, acc, fn
          {:alias, _, [{:__aliases__, _, parts} | rest] = args} = n, {b, t} ->
            bound = alias_bindings(args)

            t =
              if bound == [List.last(parts)] and find_as_value(rest) == nil,
                do: MapSet.put(t, parts),
                else: t

            {n, {MapSet.union(b, MapSet.new(bound)), t}}

          {:alias, _, args} = n, {b, t} when is_list(args) ->
            {n, {MapSet.union(b, MapSet.new(alias_bindings(args))), t}}

          {:defmodule, _, [{:__aliases__, _, [first | _]} | _]} = n, {b, t} ->
            {n, {MapSet.put(b, first), t}}

          n, acc ->
            {n, acc}
        end)

      acc
    end)
  end

  # First segment of every alias reference (`Helpers` in `Helpers.go()`
  # or `%Helpers{}`) — a module name the code relies on resolving.
  defp alias_heads(body_nodes) do
    Enum.reduce(body_nodes, MapSet.new(), fn node, acc ->
      {_, acc} =
        Macro.prewalk(node, acc, fn
          {:__aliases__, _, [first | _]} = n, a when is_atom(first) -> {n, MapSet.put(a, first)}
          n, a -> {n, a}
        end)

      acc
    end)
  end

  defp build_alias_op(body_info, target_module) do
    anchor =
      case last_header_line(body_info) do
        nil -> body_info.defmod_open_line
        line -> line
      end

    # Replace `lines[anchor]` (1-idx) with itself + the new alias on the
    # following line. We can't read the original line here, so model the
    # insert as "append text on the line below". Since apply_line_op
    # replaces start..end with text, we use start=end=anchor+1 with empty
    # range… but that's an insert-at-position, not a replacement.
    # Simplest: use a marker string and handle as a special case below.
    {anchor + 1, anchor, "  alias #{target_module}"}
  end

  # --- caller rewriting --------------------------------------------------

  # `{name, arity}` for every arity each definition can be called with.
  defp callable_keys(defs) do
    defs
    |> Enum.flat_map(fn d -> Enum.map(Definition.callable_arities(d), &{d.name, &1}) end)
    |> MapSet.new()
  end

  # Surviving defs in `promote_keys` (private helpers the target now
  # calls remotely) are also flipped to public + `@doc false` here, so a
  # def that is both rewritten and promoted gets a single line op.
  defp build_rewrite_ops(
         all_defs,
         source_module,
         closure_keys,
         rewrite_keys,
         target_parts,
         promote_keys,
         lines
       ) do
    all_defs
    |> Enum.filter(&(&1.module == source_module))
    |> Enum.reject(fn d -> MapSet.member?(closure_keys, {d.name, d.arity}) end)
    |> Enum.flat_map(fn d ->
      promote? = MapSet.member?(promote_keys, {d.name, d.arity})
      d_out = if promote?, do: promote_definition(d), else: d

      # An ambiguous def has a non-allowlisted attribute between its attrs
      # and its clauses; re-rendering the whole range would drop it. Only
      # touch the clauses there and leave the attrs (and that attribute) alone.
      d_out = if d.ambiguous, do: clauses_only(d_out), else: d_out

      text =
        case rewrite_def(d_out, rewrite_keys, target_parts) do
          nil when promote? ->
            d.range |> slice_range_text(lines) |> flip_private_keyword_in_text(d)

          nil ->
            nil

          new_nodes ->
            Enum.map_join(new_nodes, "\n", &render_node/1)
        end

      case text do
        nil ->
          []

        text ->
          text = if promote?, do: prepend_doc_false(text, d), else: text
          {s, e} = op_lines(d)
          [{s, e, text}]
      end
    end)
  end

  defp clauses_only(%Definition{parts: %{clauses: clauses}} = d), do: %{d | nodes: clauses}

  defp op_lines(%Definition{ambiguous: nil, range: range}),
    do: {Keyword.fetch!(range.start, :line), Keyword.fetch!(range.end, :line)}

  defp op_lines(%Definition{parts: %{clauses: clauses}, range: range}) do
    ranges = clauses |> Enum.map(&Sourceror.get_range/1) |> Enum.reject(&is_nil/1)

    case ranges do
      [] ->
        {Keyword.fetch!(range.start, :line), Keyword.fetch!(range.end, :line)}

      _ ->
        # Comments hang off the clause and are re-rendered with it, so the
        # replaced range must start at the earliest one.
        comment_lines =
          clauses
          |> Enum.flat_map(&(&1 |> elem(1) |> Keyword.get(:leading_comments, [])))
          |> Enum.map(& &1.line)

        {(comment_lines ++ Enum.map(ranges, &Keyword.fetch!(&1.start, :line))) |> Enum.min(),
         ranges |> Enum.map(&Keyword.fetch!(&1.end, :line)) |> Enum.max()}
    end
  end

  # Walk each AST node of a surviving def. Returns the rewritten node
  # list if anything changed, otherwise nil.
  defp rewrite_def(definition, rewrite_keys, target_parts) do
    {new_nodes, changed?} =
      Enum.map_reduce(definition.nodes, false, fn node, acc ->
        {new_node, node_changed?} =
          rewrite_def_body(node, rewrite_keys, target_parts)

        {new_node, acc or node_changed?}
      end)

    if changed?, do: new_nodes, else: nil
  end

  # Walk one AST node, qualifying bare local function references to
  # `Target.name(...)` where `Target` is the alias spelled by
  # `target_parts` (e.g. `[:MyTarget]` to qualify against an aliased
  # target module, or `[:MyApp, :Source]` to qualify against a full
  # source module path). Skips def heads — the head's `{name, _, args}`
  # shape would otherwise look like a call. Returns `{ast, changed?}`.
  # Used in two directions: target-bound rewriting of extracted bodies
  # (one-atom alias) and source-staying rewriting of survivor bodies
  # whose calls now have to cross modules (full-path).
  # Attributes (@spec, @doc, @type, etc.) live in a different namespace
  # than function calls -- a local type or literal value that happens to
  # share a name/arity with an extracted function must never be treated
  # as a call to it. Type qualification for @spec/@callback/@macrocallback
  # is handled separately by Adze.Types.qualify/3; every other attribute
  # is left untouched. This clause must come first so it takes precedence
  # over the map_size(keys) == 0 short-circuit and the generic clause below.
  defp rewrite_def_body({:@, _, _} = node, _keys, _target_parts), do: {node, false}

  defp rewrite_def_body(node, keys, _target_parts) when map_size(keys) == 0,
    do: {node, false}

  defp rewrite_def_body({kind, m, [head, body]}, keys, target_parts)
       when kind in [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp] do
    {new_body, changed?} = rewrite_locals(body, keys, target_parts)
    {{kind, m, [head, new_body]}, changed?}
  end

  defp rewrite_def_body(node, keys, target_parts) do
    rewrite_locals(node, keys, target_parts)
  end

  # A hand-rolled walk rather than `Macro.prewalk/3`: the pipe clauses
  # must control descent into their right-hand side. With prewalk, a
  # non-matching `x |> foo(2)` (effective arity 2) would be descended
  # into and `foo(2)` would then match the bare-call clause at arity 1,
  # qualifying it to a function that doesn't exist at that arity.
  defp rewrite_locals(ast, keys, target_parts) do
    walk_locals(ast, keys, target_parts)
  end

  # Capture: &name/arity → &Target.name/arity
  defp walk_locals(
         {:&, m, [{:/, sm, [{name, _nm, ctx}, {:__block__, _am, [arity]} = arity_node]}]} = node,
         keys,
         target_parts
       )
       when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) and is_integer(arity) do
    if MapSet.member?(keys, {name, arity}) do
      {{:&, m, [{:/, sm, [qualified(target_parts, name, [no_parens: true], []), arity_node]}]},
       true}
    else
      {node, false}
    end
  end

  # Pipe: `x |> name(...)` — at the AST level `name(...)` has its
  # written arity, but the pipe injects `x` as the first arg, so the
  # effective arity is len(args) + 1. Mirrors Adze.Deps's pipe
  # expansion. The rewritten rhs keeps its original args; the pipe
  # still feeds the extra arg. The rhs call itself is never re-examined
  # as a bare call — only its arguments are walked.
  defp walk_locals({:|>, m, [lhs, {name, rm, rhs_args}]}, keys, target_parts)
       when is_atom(name) and is_list(rhs_args) do
    {new_lhs, lhs_changed?} = walk_locals(lhs, keys, target_parts)
    {new_args, args_changed?} = walk_locals(rhs_args, keys, target_parts)

    if MapSet.member?(keys, {name, length(rhs_args) + 1}) do
      {{:|>, m, [new_lhs, qualified(target_parts, name, rm, new_args)]}, true}
    else
      {{:|>, m, [new_lhs, {name, rm, new_args}]}, lhs_changed? or args_changed?}
    end
  end

  # `x |> name` (no parens — effective arity 1)
  defp walk_locals({:|>, m, [lhs, {name, rm, ctx} = rhs]}, keys, target_parts)
       when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) do
    {new_lhs, lhs_changed?} = walk_locals(lhs, keys, target_parts)

    if MapSet.member?(keys, {name, 1}) do
      {{:|>, m, [new_lhs, qualified(target_parts, name, rm, [])]}, true}
    else
      {{:|>, m, [new_lhs, rhs]}, lhs_changed?}
    end
  end

  # Bare local call: name(args...) → Target.name(args...)
  defp walk_locals({name, meta, args}, keys, target_parts)
       when is_atom(name) and is_list(args) do
    {new_args, args_changed?} = walk_locals(args, keys, target_parts)

    if MapSet.member?(keys, {name, length(args)}) do
      {qualified(target_parts, name, meta, new_args), true}
    else
      {{name, meta, new_args}, args_changed?}
    end
  end

  # Any other call form (remote call, anonymous call, ...): walk both
  # the callee and the arguments.
  defp walk_locals({form, meta, args}, keys, target_parts) when is_list(args) do
    {new_form, form_changed?} = walk_locals(form, keys, target_parts)
    {new_args, args_changed?} = walk_locals(args, keys, target_parts)
    {{new_form, meta, new_args}, form_changed? or args_changed?}
  end

  defp walk_locals({a, b}, keys, target_parts) do
    {new_a, a_changed?} = walk_locals(a, keys, target_parts)
    {new_b, b_changed?} = walk_locals(b, keys, target_parts)
    {{new_a, new_b}, a_changed? or b_changed?}
  end

  defp walk_locals(list, keys, target_parts) when is_list(list) do
    Enum.map_reduce(list, false, fn item, acc ->
      {new_item, changed?} = walk_locals(item, keys, target_parts)
      {new_item, acc or changed?}
    end)
  end

  defp walk_locals(other, _keys, _target_parts), do: {other, false}

  defp qualified(target_parts, name, meta, args) do
    {{:., [], [{:__aliases__, [], target_parts}, name]}, meta, args}
  end

  # The inserted `alias TargetModule` is only useful when at least one
  # surviving def in the source module calls the extracted target. Public
  # API entry points (zero internal callers) leave the alias unused →
  # `mix compile` warning. Skip the insert in that case.
  defp target_needs_alias_in_source?(source, def_key, source_module, closure_defs, opts) do
    closure_keys = MapSet.new(closure_defs, &{&1.name, &1.arity})

    case Deps.deps(source, opts) do
      {:ok, %{modules: modules}} ->
        case Enum.find(modules, &(&1.name == source_module)) do
          nil ->
            false

          mod ->
            Enum.any?(mod.defs, fn d ->
              {d.name, d.arity} not in closure_keys and def_key in d.calls
            end)
        end

      _ ->
        # Failed to analyze — be conservative and insert the alias
        # (an unused alias is a warning; a missing one is a compile error).
        true
    end
  end

  # The alias goes after the last "header" node — the conventional top of
  # a module: `@moduledoc`, `use`, `import`, `alias`, `require`. Falling
  # back to `defmod_open_line` would land us between `defmodule X do` and
  # an existing `@moduledoc`, which violates style.
  defp last_header_line(body_info) do
    (body_info.directives ++ body_info.moduledoc_nodes)
    |> Enum.flat_map(fn node ->
      case Sourceror.get_range(node) do
        nil -> []
        r -> [Keyword.fetch!(r.end, :line)]
      end
    end)
    |> case do
      [] -> nil
      lines -> Enum.max(lines)
    end
  end

  # --- formatting / diff -------------------------------------------------

  # `formatter_opts` lets callers pass through the project's
  # `.formatter.exs` configuration (notably `:locals_without_parens`
  # expanded from `:import_deps` — Ecto's `field`, `belongs_to`, `from`;
  # Phoenix's `live_redirect`, etc.). Without that, the formatter
  # parenthesizes every macro call site, producing huge cosmetic diffs
  # that obscure the real edit. `extract_file/2` resolves the right
  # opts via `Mix.Tasks.Format.formatter_for_file/1` when running
  # under `mix adze`; the in-memory `extract/2` path defaults to `[]`.
  defp reformat(source, formatter_opts) do
    formatted =
      source
      |> Code.format_string!(formatter_opts)
      |> IO.iodata_to_binary()

    if String.ends_with?(formatted, "\n"), do: formatted, else: formatted <> "\n"
  rescue
    e -> throw({:format, e})
  end
end
