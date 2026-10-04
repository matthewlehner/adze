defmodule Adze.Extract.Target do
  @moduledoc false
  # Builds the new module's file: the kept directives, then each closure
  # definition — sliced from the source verbatim where possible, rendered
  # from AST when local types, `__MODULE__` or calls back into the source
  # module need qualifying.

  alias Adze.Extract.{LocalCalls, Promote, Render}
  alias Adze.Types

  @type ctx :: %{
          target_module: String.t(),
          source_module: String.t(),
          directives: [Macro.t()],
          type_index: Types.type_index(),
          source_remaining_keys: MapSet.t(),
          promoted_keys: MapSet.t(),
          formatter_opts: keyword()
        }

  @spec build_target_file(String.t(), [Adze.Definition.t()], ctx()) :: String.t()
  def build_target_file(source, closure_defs, %{
        target_module: target_module,
        source_module: source_module,
        directives: directives,
        type_index: type_index,
        source_remaining_keys: source_remaining_keys,
        promoted_keys: promoted_keys,
        formatter_opts: formatter_opts
      }) do
    source_lines = String.split(source, "\n")

    directive_blocks =
      directives
      |> Enum.map(&render_directive(&1, source_lines))
      |> Enum.reject(&(&1 == ""))

    closure_blocks =
      Enum.map(closure_defs, fn d ->
        rendered =
          render_closure_def(d, source_lines, type_index, source_module, source_remaining_keys)

        if MapSet.member?(promoted_keys, {d.name, d.arity}) do
          rendered
          |> Promote.flip_private_keyword_in_text(d)
          |> Promote.prepend_doc_false(d)
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
    Render.reformat(raw, formatter_opts)
  end

  # Trimmed aliases are synthesized without position metadata, so print
  # them from the AST; everything else is sliced verbatim.
  defp render_directive({:alias, [], _} = node, _source_lines), do: Sourceror.to_string(node)
  defp render_directive(node, source_lines), do: Render.slice_node_text(node, source_lines)

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
          :unchanged -> Render.slice_range_text(definition.range, source_lines)
        end

      true ->
        Render.slice_range_text(definition.range, source_lines)
    end
  end

  # We re-use the rewriting walker as our detector — if it rewrote anything,
  # render the modified AST; if not, the caller falls back to source slicing.
  defp try_rewrite_source_local(definition, source_module, source_remaining_keys) do
    source_parts = source_module |> String.split(".") |> Enum.map(&String.to_atom/1)

    {new_nodes, any_changed?} =
      Enum.map_reduce(definition.nodes, false, fn node, acc ->
        {new_node, changed?} =
          LocalCalls.rewrite_def_body(node, source_remaining_keys, source_parts)

        {new_node, acc or changed?}
      end)

    if any_changed? do
      {:changed, Enum.map_join(new_nodes, "\n", &Render.render_node/1)}
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
    |> Enum.map_join("\n", fn
      {:@, _, [{kind, _, _}]} = node when kind in [:spec, :callback, :macrocallback] ->
        node
        |> Types.qualify(type_index, source_module)
        |> rewrite_module_macro(source_module)
        |> Render.render_node()

      node ->
        node
        |> rewrite_module_macro(source_module)
        |> LocalCalls.rewrite_def_body(source_remaining_keys, source_parts)
        |> elem(0)
        |> Render.render_node()
    end)
  end

  defp rewrite_module_macro(node, source_module) do
    parts = source_module |> String.split(".") |> Enum.map(&String.to_atom/1)

    Macro.prewalk(node, fn
      {:__MODULE__, meta, _ctx} -> {:__aliases__, meta, parts}
      n -> n
    end)
  end
end
