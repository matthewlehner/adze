defmodule Adze.Extract.Callers do
  @moduledoc false
  # Cross-file half of extract: build the project rewrite (inject the new
  # source, create the target file), retarget `Source.fun(...)` call sites
  # in every other file to `Target.fun(...)`, and refuse the cases the
  # rewrite can't handle (moved macros without `require`, importers).

  alias Adze.ProjectRewrite

  def run_project_rewrite(source_path, single, opts) do
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

  # --- refusals ---------------------------------------------------------

  # Cross-file callers: any caller diff means a call site was rewritten
  # to `Target.m(x)` without a `require`.
  def check_moved_macros_external(single, caller_diffs) do
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
  def check_importers(rewrite, single, source_path) do
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
end
