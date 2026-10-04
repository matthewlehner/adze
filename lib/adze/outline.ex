defmodule Adze.Outline do
  @moduledoc """
  Parse Elixir source and return its structural outline.

  Each top-level `defmodule` becomes a node with its children:
  defs, defmacros, attributes, directives, defstructs, nested modules.
  Every node carries a line range so callers can `Read` just the
  bytes they need.
  """

  alias Adze.AST

  @def_kinds [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]
  @directives [:alias, :import, :require, :use]
  @doc_attrs [
    :moduledoc,
    :doc,
    :spec,
    :type,
    :typep,
    :opaque,
    :callback,
    :macrocallback,
    :impl,
    :behaviour,
    :derive
  ]

  @type definition :: map()

  @spec outline_file(Path.t()) :: {:ok, map()} | {:error, term()}
  def outline_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> outline(source, file: path)
      {:error, reason} -> {:error, {:file_read, reason}}
    end
  end

  @spec outline(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def outline(source, opts \\ []) when is_binary(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        {:ok,
         %{
           file: Keyword.get(opts, :file),
           definitions: collect_top(ast)
         }}

      {:error, reason} ->
        {:error, {:parse, reason}}
    end
  end

  # --- top-level traversal -------------------------------------------------

  defp collect_top({:__block__, _meta, exprs}), do: Enum.flat_map(exprs, &top_definition/1)
  defp collect_top(expr), do: top_definition(expr)

  defp top_definition({:defmodule, _meta, [alias_ast, [{_, body}]]} = node) do
    [
      %{
        kind: :defmodule,
        name: alias_name(alias_ast),
        range: AST.line_range(node),
        children: collect_children(body)
      }
    ]
  end

  defp top_definition({:defprotocol, _meta, [alias_ast, [{_, body}]]} = node) do
    [
      %{
        kind: :defprotocol,
        name: alias_name(alias_ast),
        range: AST.line_range(node),
        children: collect_children(body)
      }
    ]
  end

  defp top_definition({:defimpl, _meta, args} = node) do
    [
      %{
        kind: :defimpl,
        name: defimpl_name(args),
        range: AST.line_range(node)
      }
    ]
  end

  defp top_definition(other) do
    [%{kind: :other, snippet: snippet(other), range: AST.line_range(other)}]
  end

  # --- module body --------------------------------------------------------

  defp collect_children({:__block__, _meta, exprs}) do
    exprs
    |> Enum.map(&child_definition/1)
    |> Enum.reject(&is_nil/1)
  end

  defp collect_children(expr) do
    case child_definition(expr) do
      nil -> []
      definition -> [definition]
    end
  end

  defp child_definition({kind, _meta, [head | _]} = node) when kind in @def_kinds do
    {name, arity, has_guard} = name_arity(head)

    %{
      kind: kind,
      name: name,
      arity: arity,
      private: kind in [:defp, :defmacrop, :defguardp],
      guards: has_guard,
      range: AST.line_range(node)
    }
  end

  defp child_definition({:defstruct, _meta, [fields]} = node) do
    %{kind: :defstruct, fields: struct_fields(fields), range: AST.line_range(node)}
  end

  defp child_definition({:defexception, _meta, [fields]} = node) do
    %{kind: :defexception, fields: struct_fields(fields), range: AST.line_range(node)}
  end

  defp child_definition({kind, _meta, [target | _]} = node) when kind in @directives do
    %{kind: kind, target: alias_name(target), range: AST.line_range(node)}
  end

  defp child_definition({:@, _meta, [{name, _, value_ast}]} = node) when is_atom(name) do
    %{
      kind: :attribute,
      name: name,
      doc: name in @doc_attrs,
      target: attribute_target(name, value_ast),
      range: AST.line_range(node)
    }
  end

  defp child_definition({:defmodule, _, _} = node), do: hd(top_definition(node))
  defp child_definition({:defprotocol, _, _} = node), do: hd(top_definition(node))
  defp child_definition({:defimpl, _, _} = node), do: hd(top_definition(node))

  defp child_definition(_other), do: nil

  # --- helpers ------------------------------------------------------------

  defp name_arity({:when, _, [head, _guard]}) do
    {name, arity, _} = name_arity(head)
    {name, arity, true}
  end

  # `def unquote(head)`: the whole head is unquoted. Checked before the
  # normal-name clause so it isn't read as a def named `unquote/1`
  # (matches `Adze.Definition`).
  defp name_arity({:unquote, _, args}) when is_list(args), do: {nil, length(args), false}

  defp name_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args), false}

  defp name_arity({name, _, nil}) when is_atom(name), do: {name, 0, false}

  # `def unquote(name)(...)`: name isn't static. Same `nil` as
  # `Adze.Definition`, with the real arity.
  defp name_arity({_, _, args}) when is_list(args), do: {nil, length(args), false}
  defp name_arity(_), do: {nil, 0, false}

  # Names are shown as written; `__MODULE__.Inner` and other non-atom
  # parts fall through to the source snippet.
  defp alias_name({:__aliases__, _, parts} = ast) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1),
      do: parts |> Enum.map_join(".", &Atom.to_string/1),
      else: snippet(ast)
  end

  defp alias_name(atom) when is_atom(atom), do: inspect(atom)
  defp alias_name(other), do: snippet(other)

  # Sourceror wraps literals — `[:id, :name, count: 0]` parses as
  #   {:__block__, _, [[atom_block, atom_block, {key_block, val_block}]]}
  defp struct_fields({:__block__, _, [inner]}), do: struct_fields(inner)

  defp struct_fields(list) when is_list(list) do
    Enum.map(list, fn
      {key_ast, _v} -> AST.unwrap_atom(key_ast)
      k when is_atom(k) -> k
      other -> AST.unwrap_atom(other)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp struct_fields(_), do: []

  defp defimpl_name([protocol | rest]) do
    proto = alias_name(protocol)

    for_target =
      Enum.find_value(rest, fn
        opts when is_list(opts) -> opts[:for] |> maybe_target()
        _ -> nil
      end)

    case for_target do
      nil -> proto
      target -> "#{proto}, for: #{target}"
    end
  end

  defp defimpl_name(_), do: "unknown"

  defp maybe_target(nil), do: nil
  defp maybe_target(target), do: alias_name(target)

  # @spec foo(...) :: ... — extract the function name being spec'd
  defp attribute_target(:spec, [{:"::", _, [{name, _, _args}, _]}]) when is_atom(name), do: name
  defp attribute_target(:type, [{:"::", _, [{name, _, _args}, _]}]) when is_atom(name), do: name
  defp attribute_target(:typep, [{:"::", _, [{name, _, _args}, _]}]) when is_atom(name), do: name
  defp attribute_target(:opaque, [{:"::", _, [{name, _, _args}, _]}]) when is_atom(name), do: name

  defp attribute_target(:impl, [value]) when is_atom(value) or is_boolean(value), do: value
  defp attribute_target(:behaviour, [value]), do: alias_name(value)
  defp attribute_target(_, _), do: nil

  defp snippet(ast) do
    ast |> Macro.to_string() |> String.slice(0, 60)
  rescue
    _ -> "<unprintable>"
  end
end
