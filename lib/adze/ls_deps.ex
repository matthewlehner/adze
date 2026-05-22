defmodule Adze.LsDeps do
  @moduledoc """
  Recursive views over the intra-module call graph.

  Two ops, both read-only:

    * `ls_deps/2` — DFS tree rooted at a `{name, arity}` definition. Each
      node is visited at most once across the whole tree: re-encounters
      (cycles *or* diamond joins) are marked `repeat: true` and not
      re-expanded. JSON output preserves the same shape so the full graph
      can be reconstructed by callers if needed.

    * `ls_extract/2` — the intra-module-exclusive closure: the target plus
      every `defp` reachable from the closure whose every caller (within
      the same module) is already in the closure. Suggestion only — used
      to scope what `extract!` would later cut.

  Public defs are never pulled into the closure: we can't see their
  callers outside this file, so we conservatively leave them put.
  Both ops dispatch per module that contains the definition, so a
  name+arity that exists in two sibling modules surfaces twice.
  """

  alias Adze.Deps

  @type definition :: {atom(), non_neg_integer()}

  # --- file/source entry points ------------------------------------------

  @spec ls_deps_file(Path.t(), definition()) :: {:ok, map()} | {:error, term()}
  def ls_deps_file(path, definition),
    do: with_deps_file(path, &ls_deps_from(&1, definition))

  @spec ls_deps(String.t(), definition(), keyword()) :: {:ok, map()} | {:error, term()}
  def ls_deps(source, definition, opts \\ []) do
    with_deps_source(source, opts, &ls_deps_from(&1, definition))
  end

  @spec ls_extract_file(Path.t(), definition()) :: {:ok, map()} | {:error, term()}
  def ls_extract_file(path, definition),
    do: with_deps_file(path, &ls_extract_from(&1, definition))

  @spec ls_extract(String.t(), definition(), keyword()) :: {:ok, map()} | {:error, term()}
  def ls_extract(source, definition, opts \\ []) do
    with_deps_source(source, opts, &ls_extract_from(&1, definition))
  end

  defp with_deps_file(path, fun) do
    case Deps.deps_file(path) do
      {:ok, deps} -> {:ok, fun.(deps)}
      err -> err
    end
  end

  defp with_deps_source(source, opts, fun) do
    case Deps.deps(source, opts) do
      {:ok, deps} -> {:ok, fun.(deps)}
      err -> err
    end
  end

  # --- ls-deps tree ------------------------------------------------------

  defp ls_deps_from(deps, {name, arity} = definition) do
    modules =
      deps.modules
      |> Enum.filter(&has_def?(&1, name, arity))
      |> Enum.map(fn m ->
        {root, _visited} = build_tree(m, definition, MapSet.new())
        %{name: m.name, root: root}
      end)

    %{file: deps[:file], definition: definition, modules: modules}
  end

  defp build_tree(mod, {name, arity} = definition, visited) do
    visited = MapSet.put(visited, definition)

    case find_def(mod, name, arity) do
      nil ->
        {missing_node(name, arity), visited}

      entry ->
        {children_rev, visited} =
          Enum.reduce(entry.calls, {[], visited}, fn callee, {acc, v} ->
            if MapSet.member?(v, callee) do
              {[repeat_node(mod, callee) | acc], v}
            else
              {child, v2} = build_tree(mod, callee, v)
              {[child | acc], v2}
            end
          end)

        node = %{
          name: name,
          arity: arity,
          kind: entry.kind,
          private: entry.private,
          range: entry.range,
          repeat: false,
          leaf: entry.calls == [],
          children: Enum.reverse(children_rev)
        }

        {node, visited}
    end
  end

  defp repeat_node(mod, {name, arity}) do
    base = %{name: name, arity: arity, repeat: true, leaf: false, children: []}

    case find_def(mod, name, arity) do
      nil -> Map.merge(base, %{kind: :unknown, private: false, range: nil})
      e -> Map.merge(base, %{kind: e.kind, private: e.private, range: e.range, leaf: e.calls == []})
    end
  end

  defp missing_node(name, arity) do
    %{
      name: name,
      arity: arity,
      kind: :unknown,
      private: false,
      range: nil,
      repeat: false,
      leaf: true,
      children: []
    }
  end

  # --- ls-extract closure ------------------------------------------------

  defp ls_extract_from(deps, {name, arity} = definition) do
    modules =
      deps.modules
      |> Enum.filter(&has_def?(&1, name, arity))
      |> Enum.map(fn m ->
        %{name: m.name, target: definition, closure: closure(m, definition)}
      end)

    %{file: deps[:file], definition: definition, modules: modules}
  end

  defp closure(mod, target) do
    callers = build_callers_index(mod)
    private_keys = MapSet.new(for d <- mod.defs, d.private, do: {d.name, d.arity})
    sccs = private_sccs(mod, private_keys)

    set = grow_sccs(MapSet.new([target]), sccs, callers)

    set
    |> Enum.map(fn {n, a} -> find_def(mod, n, a) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&sort_key/1)
    |> Enum.map(fn d ->
      %{name: d.name, arity: d.arity, kind: d.kind, private: d.private, range: d.range}
    end)
  end

  # Strongly connected components of the private call subgraph. A mutually-
  # recursive pair `ping/2` ↔ `pong/2` ends up as one SCC of size 2; a
  # self-recursive `loop/2` is a singleton SCC with a self-loop. Without
  # this collapsing step, the closure grower stalls on cycles because no
  # single node ever has "all callers in closure" — its cycle-mate is the
  # blocker.
  defp private_sccs(mod, private_keys) do
    g = :digraph.new()

    try do
      Enum.each(private_keys, &:digraph.add_vertex(g, &1))

      Enum.each(mod.defs, fn d ->
        from = {d.name, d.arity}

        if MapSet.member?(private_keys, from) do
          Enum.each(d.calls, fn to ->
            if MapSet.member?(private_keys, to), do: :digraph.add_edge(g, from, to)
          end)
        end
      end)

      g
      |> :digraph_utils.strong_components()
      |> Enum.map(&MapSet.new/1)
    after
      :digraph.delete(g)
    end
  end

  defp grow_sccs(closure, sccs, callers) do
    case Enum.find(sccs, &addable_scc?(&1, closure, callers)) do
      nil -> closure
      scc -> grow_sccs(MapSet.union(closure, scc), sccs, callers)
    end
  end

  defp addable_scc?(scc, closure, callers) do
    if MapSet.disjoint?(scc, closure) do
      case external_callers(scc, callers) do
        [] -> false
        external -> Enum.all?(external, &MapSet.member?(closure, &1))
      end
    else
      false
    end
  end

  defp external_callers(scc, callers) do
    scc
    |> Enum.flat_map(&Map.get(callers, &1, []))
    |> Enum.reject(&MapSet.member?(scc, &1))
    |> Enum.uniq()
  end

  defp build_callers_index(mod) do
    mod.defs
    |> Enum.flat_map(fn d -> Enum.map(d.calls, fn callee -> {callee, {d.name, d.arity}} end) end)
    |> Enum.group_by(fn {callee, _} -> callee end, fn {_, caller} -> caller end)
    |> Map.new(fn {k, vs} -> {k, Enum.uniq(vs)} end)
  end

  # --- helpers -----------------------------------------------------------

  defp has_def?(mod, name, arity) do
    Enum.any?(mod.defs, &(&1.name == name and &1.arity == arity))
  end

  defp find_def(mod, name, arity) do
    Enum.find(mod.defs, &(&1.name == name and &1.arity == arity))
  end

  defp sort_key(%{range: %{start: s}, name: n, arity: a}), do: {s, n, a}
  defp sort_key(%{name: n, arity: a}), do: {0, n, a}
end
