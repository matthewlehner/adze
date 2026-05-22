defmodule Adze.Formatter do
  @moduledoc """
  Render outline results as either compact text (for humans + LLMs)
  or JSON (for tools).
  """

  @doc false
  def format(outline, :json) do
    outline |> normalize() |> JSON.encode!()
  end

  def format(outline, :text) do
    file_line =
      case outline[:file] do
        nil -> "<source>"
        path -> path
      end

    [
      "# #{file_line}",
      Enum.map(outline.definitions, &format_definition(&1, 0))
    ]
    |> IO.iodata_to_binary()
  end

  @doc false
  def format_deps(deps, :json) do
    deps |> normalize() |> JSON.encode!()
  end

  def format_deps(deps, :text) do
    file_line =
      case deps[:file] do
        nil -> "<source>"
        path -> path
      end

    [
      "# #{file_line}\n",
      Enum.map(deps.modules, &format_deps_module/1)
    ]
    |> IO.iodata_to_binary()
  end

  defp format_deps_module(%{name: name, range: r, defs: defs}) do
    [
      "\ndefmodule ",
      name,
      "   ",
      range_str(r),
      "\n",
      Enum.map(defs, &format_def_entry/1)
    ]
  end

  defp format_def_entry(%{
         name: name,
         arity: arity,
         kind: kind,
         private: priv,
         range: r,
         calls: calls
       }) do
    tag =
      cond do
        priv and kind == :defp -> " [private]"
        priv -> " [#{kind}, private]"
        kind == :def -> ""
        true -> " [#{kind}]"
      end

    head = [
      "  ",
      to_string(name),
      "/",
      Integer.to_string(arity),
      tag,
      "   ",
      range_str(r),
      "\n"
    ]

    call_lines =
      Enum.map(calls, fn {n, a} ->
        ["    → ", to_string(n), "/", Integer.to_string(a), "\n"]
      end)

    [head, call_lines]
  end

  # --- extract-private ---------------------------------------------------

  @doc false
  def format_extract_private(result, :json) do
    %{
      op: "extract-private",
      module: result.module,
      name: Atom.to_string(result.name),
      arity: result.arity,
      from_kind: Atom.to_string(result.from_kind),
      to_kind: Atom.to_string(result.to_kind),
      diff: result.diff,
      new_source: result.new_source
    }
    |> JSON.encode!()
  end

  def format_extract_private(result, :text) do
    header = [
      "# extract-private ",
      result.module,
      ".",
      Atom.to_string(result.name),
      "/",
      Integer.to_string(result.arity),
      "   ",
      Atom.to_string(result.from_kind),
      " → ",
      Atom.to_string(result.to_kind),
      "\n"
    ]

    diff =
      case result.diff do
        "" -> "(no changes)\n"
        d -> d
      end

    IO.iodata_to_binary([header, "\n", diff])
  end

  # --- find-callers ------------------------------------------------------

  @doc false
  def format_find_callers(result, :json), do: result |> normalize() |> JSON.encode!()

  def format_find_callers(result, :text) do
    target_str = format_target(result.target)

    header = [
      "# find-callers ",
      target_str,
      "  (",
      Integer.to_string(result.total),
      " ref",
      if(result.total == 1, do: "", else: "s"),
      ")\n"
    ]

    body =
      case result.files do
        m when map_size(m) == 0 ->
          ["\n(no callers)\n"]

        m ->
          m
          |> Enum.sort_by(fn {path, _} -> path end)
          |> Enum.map(&format_caller_file/1)
      end

    IO.iodata_to_binary([header, body])
  end

  defp format_target(%{module: m, function: f, arity: :any}) do
    [m, ".", Atom.to_string(f), "/*"]
  end

  defp format_target(%{module: m, function: f, arity: a}) do
    [m, ".", Atom.to_string(f), "/", Integer.to_string(a)]
  end

  defp format_caller_file({path, callers}) do
    entries =
      callers
      |> Enum.sort_by(& &1.line)
      |> Enum.map(fn c ->
        kind_tag =
          case c.kind do
            :call -> "call   "
            :capture -> "capture"
          end

        [
          "  L",
          String.pad_leading(Integer.to_string(c.line), 4),
          "  ",
          kind_tag,
          " /",
          Integer.to_string(c.arity),
          "  ",
          c.snippet,
          "\n"
        ]
      end)

    ["\n# ", path, "\n", entries]
  end

  # --- aliases -----------------------------------------------------------

  @doc false
  def format_aliases(result, :json), do: result |> normalize() |> JSON.encode!()

  def format_aliases(result, :text) do
    file_line =
      case result[:file] do
        nil -> "<source>"
        path -> path
      end

    body =
      case result.modules do
        [] -> ["\n(no modules)\n"]
        mods -> Enum.map(mods, &format_aliases_module/1)
      end

    IO.iodata_to_binary(["# ", file_line, "\n", body])
  end

  defp format_aliases_module(%{name: name, range: r, directives: directives}) do
    body =
      case directives do
        [] -> ["  (no directives)\n"]
        ds -> Enum.map(ds, &format_directive_entry/1)
      end

    ["\ndefmodule ", name, "   ", range_str(r), "\n", body]
  end

  defp format_directive_entry(d) do
    # Render the raw source slice so `import Enum, only: [map: 2]` and
    # `use GenServer, restart: :transient` show their opts inline.
    # Multi-line directives get collapsed to one line for the listing —
    # the line range points at the full source if the user needs more.
    rendered =
      if d.group do
        # Group-form: the raw text is identical across members, so
        # rendering it would duplicate. Show the expanded target instead;
        # `[group]` flags the original brace form.
        "alias #{d.target}  [group]"
      else
        d.text
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
      end

    [
      "  ",
      String.pad_trailing(range_str(d.range), 7),
      "  ",
      rendered,
      "\n"
    ]
  end

  # --- ls-deps -----------------------------------------------------------

  @doc false
  def format_ls_deps(result, :json), do: result |> normalize() |> JSON.encode!()

  def format_ls_deps(result, :text) do
    file_line =
      case result[:file] do
        nil -> "<source>"
        path -> path
      end

    {n, a} = result.definition

    header = [
      "# ",
      file_line,
      "\n",
      "definition: ",
      to_string(n),
      "/",
      Integer.to_string(a),
      "\n"
    ]

    body =
      case result.modules do
        [] -> ["\n(no module contains ", to_string(n), "/", Integer.to_string(a), ")\n"]
        mods -> Enum.map(mods, &format_ls_deps_module/1)
      end

    IO.iodata_to_binary([header, body])
  end

  defp format_ls_deps_module(%{name: name, root: root}) do
    ["\ndefmodule ", name, "\n", render_node(root, "", :root)]
  end

  # `prefix` is the column-prefix carried down from ancestors (chars that
  # precede this node's connector). `pos` is :root | :mid | :last and picks
  # the connector for this node's own line.
  defp render_node(node, prefix, pos) do
    {connector, child_continuation} =
      case pos do
        :root -> {"", ""}
        :mid -> {"├─ ", "│  "}
        :last -> {"└─ ", "   "}
      end

    line = [prefix, connector, node_label(node), "\n"]
    child_prefix = prefix <> child_continuation

    children = node.children
    last_idx = length(children) - 1

    child_lines =
      children
      |> Enum.with_index()
      |> Enum.map(fn {child, i} ->
        render_node(child, child_prefix, if(i == last_idx, do: :last, else: :mid))
      end)

    [line, child_lines]
  end

  defp node_label(%{name: n, arity: a} = node) do
    marker =
      cond do
        node[:repeat] -> " ↺"
        node[:leaf] -> " *"
        true -> ""
      end

    priv = if node[:private], do: " (private)", else: ""
    [to_string(n), "/", Integer.to_string(a), priv, marker]
  end

  # --- ls-extract --------------------------------------------------------

  @doc false
  def format_ls_extract(result, :json), do: result |> normalize() |> JSON.encode!()

  def format_ls_extract(result, :text) do
    file_line =
      case result[:file] do
        nil -> "<source>"
        path -> path
      end

    {n, a} = result.definition

    header = [
      "# ",
      file_line,
      "\n",
      "extract closure for ",
      to_string(n),
      "/",
      Integer.to_string(a),
      "\n"
    ]

    body =
      case result.modules do
        [] -> ["\n(no module contains ", to_string(n), "/", Integer.to_string(a), ")\n"]
        mods -> Enum.map(mods, &format_ls_extract_module/1)
      end

    IO.iodata_to_binary([header, body])
  end

  defp format_ls_extract_module(%{name: name, closure: closure}) do
    [
      "\ndefmodule ",
      name,
      "\n",
      Enum.map(closure, &format_closure_entry/1)
    ]
  end

  defp format_closure_entry(%{name: n, arity: a, private: priv}) do
    tag = if priv, do: " (private)", else: ""
    ["  ", to_string(n), "/", Integer.to_string(a), tag, "\n"]
  end

  # --- mv ----------------------------------------------------------------

  @doc false
  def format_mv(%{diff: diff} = result, :json) do
    %{op: "mv", diff: diff, new_source: result.new_source}
    |> JSON.encode!()
  end

  def format_mv(%{diff: diff}, :text) do
    case diff do
      "" -> "(no changes)\n"
      d -> d
    end
  end

  # --- extract -----------------------------------------------------------

  @doc false
  def format_extract(result, :json) do
    %{
      op: "extract",
      target_module: result.target_module,
      target_path: result.target_path,
      source_diff: result.source_diff,
      target_content: result.target_content,
      new_source: result.new_source,
      caller_diffs: Map.get(result, :caller_diffs, %{}),
      dropped_directives:
        result
        |> Map.get(:dropped_directives, [])
        |> Enum.map(fn d -> %{kind: Atom.to_string(d.kind), line: d.line, text: d.text} end)
    }
    |> JSON.encode!()
  end

  def format_extract(result, :text) do
    caller_block =
      case Map.get(result, :caller_diffs, %{}) do
        m when map_size(m) == 0 ->
          []

        m ->
          entries =
            m
            |> Enum.sort_by(fn {path, _} -> path end)
            |> Enum.map(fn {path, diff} -> ["\n# caller: ", path, "\n", diff] end)

          ["\n# caller diffs\n", entries]
      end

    dropped_block =
      case Map.get(result, :dropped_directives, []) do
        [] ->
          []

        dropped ->
          # use/import/require are never copied to the target (the
          # tool can't know without macro expansion whether the
          # closure needs them). Surface here so the AI can decide
          # what to add back to the target if compile complains.
          entries =
            dropped
            |> Enum.sort_by(& &1.line)
            |> Enum.map(fn d ->
              ["  source:", Integer.to_string(d.line), "  ", d.text, "\n"]
            end)

          [
            "\n# dropped directives (use / import / require)\n",
            "# add back to the new target module if the build needs them.\n",
            entries
          ]
      end

    IO.iodata_to_binary([
      "# new file: ",
      result.target_path,
      " (",
      result.target_module,
      ")\n",
      result.target_content,
      "\n",
      "# source diff\n",
      case result.source_diff do
        "" -> "(no changes)\n"
        d -> d
      end,
      caller_block,
      dropped_block
    ])
  end

  # --- rename ------------------------------------------------------------

  @doc false
  def format_rename(result, :json) do
    # `warnings:` and `notices:` are lists of `{tag, refs}` tuples
    # (e.g. `{:surviving_references, refs}`, `{:rewritten_short_refs,
    # refs}`); `refs` are maps with atom keys. JSON.encode! can't
    # serialize tuples or atom keys directly. `normalize/1` flattens
    # tuples → arrays and atom keys/values → strings, producing
    # `["surviving_references", [%{"path": ..., "line": ...}]]`.
    %{
      op: "rename",
      from: inspect(result.from),
      to: inspect(result.to),
      diffs: result.diffs,
      moves: result.moves,
      warnings: result.warnings,
      notices: result.notices
    }
    |> normalize()
    |> JSON.encode!()
  end

  def format_rename(result, :text) do
    header = [
      "# rename ",
      inspect(result.from),
      " → ",
      inspect(result.to),
      "\n"
    ]

    moves_block =
      case result.moves do
        m when map_size(m) == 0 ->
          []

        m ->
          lines = Enum.map(m, fn {from, to} -> ["  ", from, " → ", to, "\n"] end)
          ["\n# moves\n", lines]
      end

    diffs_block =
      case result.diffs do
        d when map_size(d) == 0 ->
          ["\n(no file changes)\n"]

        d ->
          d
          |> Enum.sort_by(fn {path, _} -> path end)
          |> Enum.map(fn {path, diff} -> ["\n# ", path, "\n", diff] end)
      end

    warnings_block =
      case result.warnings do
        [] -> []
        ws -> ["\n# warnings\n", Enum.map(ws, &format_warning/1)]
      end

    notices_block =
      case result.notices do
        [] -> []
        ns -> ["\n# notices\n", Enum.map(ns, &format_notice/1)]
      end

    IO.iodata_to_binary([header, moves_block, diffs_block, warnings_block, notices_block])
  end

  # Surviving-reference warnings get a header + a one-line-per-ref
  # listing so the locations are scannable. Other warning shapes from
  # Igniter come back as plain strings.
  defp format_warning({:surviving_references, refs}) do
    [
      "  surviving bare-alias references (would compile-break — known Igniter ",
      "same-namespace bug; rename!/1 will refuse without --force):\n",
      format_refs(refs)
    ]
  end

  defp format_warning(w) when is_binary(w), do: ["  - ", w, "\n"]
  defp format_warning(other), do: ["  - ", inspect(other), "\n"]

  # When the short-ref fix-up patched bare `OldShort.fun(...)` call
  # sites that Igniter's same-namespace rewrite missed, the locations
  # surface here so the user sees what adze touched on their behalf.
  defp format_notice({:rewritten_short_refs, refs}) do
    [
      "  rewrote ",
      Integer.to_string(length(refs)),
      " bare-alias reference(s) that Igniter's same-namespace pass left in place:\n",
      format_refs(refs)
    ]
  end

  defp format_notice(n) when is_binary(n), do: ["  - ", n, "\n"]
  defp format_notice(other), do: ["  - ", inspect(other), "\n"]

  defp format_refs(refs) do
    Enum.map(refs, fn %{path: p, line: l, short: s} ->
      ["    ", p, ":", Integer.to_string(l), "  ", Atom.to_string(s), ".…\n"]
    end)
  end

  defp format_definition(%{kind: :defmodule, name: name, range: r, children: kids}, depth) do
    [
      indent(depth),
      "\ndefmodule ",
      name,
      "   ",
      range_str(r),
      "\n",
      Enum.map(kids, &format_definition(&1, depth + 1))
    ]
  end

  defp format_definition(%{kind: :defprotocol, name: name, range: r, children: kids}, depth) do
    [
      indent(depth),
      "\ndefprotocol ",
      name,
      "   ",
      range_str(r),
      "\n",
      Enum.map(kids, &format_definition(&1, depth + 1))
    ]
  end

  defp format_definition(%{kind: :defimpl, name: name, range: r}, depth) do
    [indent(depth), "defimpl ", name, "   ", range_str(r), "\n"]
  end

  defp format_definition(%{kind: kind, name: name, arity: arity, guards: guards, range: r}, depth)
       when kind in [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate] do
    {marker, private_tag} =
      case kind do
        :def -> {" ", ""}
        :defp -> {"p", ""}
        :defmacro -> {"m", ""}
        :defmacrop -> {"m", " [private]"}
        :defguard -> {"g", ""}
        :defguardp -> {"g", " [private]"}
        :defdelegate -> {"d", ""}
      end

    guard_str = if guards, do: " when …", else: ""

    [
      indent(depth),
      marker,
      " ",
      to_string(name),
      "/",
      Integer.to_string(arity),
      guard_str,
      private_tag,
      "   ",
      range_str(r),
      "\n"
    ]
  end

  defp format_definition(%{kind: :defstruct, fields: fields, range: r}, depth) do
    [indent(depth), "defstruct ", inspect(fields), "   ", range_str(r), "\n"]
  end

  defp format_definition(%{kind: :defexception, fields: fields, range: r}, depth) do
    [indent(depth), "defexception ", inspect(fields), "   ", range_str(r), "\n"]
  end

  defp format_definition(%{kind: kind, target: target, range: r}, depth)
       when kind in [:alias, :import, :require, :use] do
    [indent(depth), to_string(kind), " ", to_string(target), "   ", range_str(r), "\n"]
  end

  defp format_definition(%{kind: :attribute, name: name, target: target, range: r}, depth) do
    # `target` is an atom (function/type name for @spec/@type/@typep,
    # boolean for `@impl true`), a string (module name for @behaviour),
    # or nil. `inspect` would prefix atoms with a colon (rendering
    # `@type :list_args` for `@type list_args :: ...`); `to_string`
    # gives the bare identifier and works correctly for booleans and
    # strings too.
    target_str = if target, do: " #{to_string(target)}", else: ""
    [indent(depth), "@", to_string(name), target_str, "   ", range_str(r), "\n"]
  end

  defp format_definition(%{kind: :other, range: r, snippet: snippet}, depth) do
    [indent(depth), "· ", snippet, "   ", range_str(r), "\n"]
  end

  defp format_definition(_, _), do: []

  defp indent(0), do: ""
  defp indent(n), do: String.duplicate("  ", n)

  defp range_str(nil), do: "?"
  defp range_str(%{start: s, end: e}) when s == e, do: "L#{s}"
  defp range_str(%{start: s, end: e}), do: "L#{s}–#{e}"

  # JSON.encode! cannot serialize atoms-as-keys for arbitrary atoms;
  # convert recursively to string keys + jsonable values.
  defp normalize(%{} = m) do
    Map.new(m, fn {k, v} -> {to_string(k), normalize(v)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  defp normalize(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&normalize/1)

  defp normalize(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom),
    do: Atom.to_string(atom)

  defp normalize(other), do: other
end
