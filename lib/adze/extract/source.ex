defmodule Adze.Extract.Source do
  @moduledoc false
  # In-file half of extract: the source file after the closure is cut
  # out, with surviving local callers qualified against the target (and
  # an `alias Target` inserted when they need one).

  alias Adze.AST
  alias Adze.Definition
  alias Adze.Deps
  alias Adze.Extract.{LocalCalls, Promote, Render}

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
  def build_new_source(
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
    # (see Promote.promote_target/2), so they're picked up here and their
    # surviving in-module callers get qualified against the target.
    rewrite_keys =
      closure_defs
      |> Enum.filter(&(&1.visibility == :public))
      |> Definition.callable_keys()

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
    Render.reformat(Enum.join(final_lines, "\n"), formatter_opts)
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
            bound = AST.alias_bindings(args)

            t =
              if bound == [List.last(parts)] and AST.alias_as(rest) == nil,
                do: MapSet.put(t, parts),
                else: t

            {n, {MapSet.union(b, MapSet.new(bound)), t}}

          {:alias, _, args} = n, {b, t} when is_list(args) ->
            {n, {MapSet.union(b, MapSet.new(AST.alias_bindings(args))), t}}

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
      d_out = if promote?, do: Promote.promote_definition(d), else: d

      # An ambiguous def has a non-allowlisted attribute between its attrs
      # and its clauses; re-rendering the whole range would drop it. Only
      # touch the clauses there and leave the attrs (and that attribute) alone.
      d_out = if d.ambiguous, do: clauses_only(d_out), else: d_out

      text =
        case rewrite_def(d_out, rewrite_keys, target_parts) do
          nil when promote? ->
            d.range |> Render.slice_range_text(lines) |> Promote.flip_private_keyword_in_text(d)

          nil ->
            nil

          new_nodes ->
            Enum.map_join(new_nodes, "\n", &Render.render_node/1)
        end

      case text do
        nil ->
          []

        text ->
          text = if promote?, do: Promote.prepend_doc_false(text, d), else: text
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
          LocalCalls.rewrite_def_body(node, rewrite_keys, target_parts)

        {new_node, acc or node_changed?}
      end)

    if changed?, do: new_nodes, else: nil
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

  # The inserted `alias TargetModule` is only useful when at least one
  # surviving def in the source module calls the extracted target. Public
  # API entry points (zero internal callers) leave the alias unused →
  # `mix compile` warning. Skip the insert in that case.
  def target_needs_alias_in_source?(source, def_key, source_module, closure_defs, opts) do
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
end
