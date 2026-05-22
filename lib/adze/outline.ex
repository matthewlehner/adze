defmodule Adze.Outline do
  @moduledoc """
  Parse Elixir source and return its structural outline.

  Each top-level `defmodule` becomes a node with its children:
  defs, defmacros, attributes, directives, defstructs, nested modules.
  Every node carries a line range so callers can `Read` just the
  bytes they need.
  """

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
        range: range(node),
        children: collect_children(body)
      }
    ]
  end

  defp top_definition({:defprotocol, _meta, [alias_ast, [{_, body}]]} = node) do
    [
      %{
        kind: :defprotocol,
        name: alias_name(alias_ast),
        range: range(node),
        children: collect_children(body)
      }
    ]
  end

  defp top_definition({:defimpl, _meta, args} = node) do
    [
      %{
        kind: :defimpl,
        name: defimpl_name(args),
        range: range(node)
      }
    ]
  end

  defp top_definition(other) do
    [%{kind: :other, snippet: snippet(other), range: range(other)}]
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
      range: range(node)
    }
  end

  defp child_definition({:defstruct, _meta, [fields]} = node) do
    %{kind: :defstruct, fields: struct_fields(fields), range: range(node)}
  end

  defp child_definition({:defexception, _meta, [fields]} = node) do
    %{kind: :defexception, fields: struct_fields(fields), range: range(node)}
  end

  defp child_definition({kind, _meta, [target | _]} = node) when kind in @directives do
    %{kind: kind, target: alias_or_atom(target), range: range(node)}
  end

  defp child_definition({:@, _meta, [{name, _, value_ast}]} = node) when is_atom(name) do
    %{
      kind: :attribute,
      name: name,
      doc: name in @doc_attrs,
      target: attribute_target(name, value_ast),
      range: range(node)
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

  defp name_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args), false}

  defp name_arity({name, _, nil}) when is_atom(name), do: {name, 0, false}
  defp name_arity(_), do: {:unknown, 0, false}

  defp alias_name({:__aliases__, _, parts}) when is_list(parts) do
    parts |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
  end

  defp alias_name(atom) when is_atom(atom), do: inspect(atom)
  defp alias_name(other), do: snippet(other)

  defp alias_or_atom({:__aliases__, _, parts}) when is_list(parts) do
    parts |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
  end

  defp alias_or_atom(atom) when is_atom(atom), do: inspect(atom)
  defp alias_or_atom(other), do: snippet(other)

  # Sourceror wraps literals — `[:id, :name, count: 0]` parses as
  #   {:__block__, _, [[atom_block, atom_block, {key_block, val_block}]]}
  defp struct_fields({:__block__, _, [inner]}), do: struct_fields(inner)

  defp struct_fields(list) when is_list(list) do
    Enum.map(list, fn
      {key_ast, _v} -> unwrap_atom(key_ast)
      k when is_atom(k) -> k
      other -> unwrap_atom(other)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp struct_fields(_), do: []

  defp unwrap_atom({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp unwrap_atom(atom) when is_atom(atom), do: atom
  defp unwrap_atom(_), do: nil

  defp defimpl_name([protocol | rest]) do
    proto = alias_or_atom(protocol)

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
  defp maybe_target(target), do: alias_or_atom(target)

  # @spec foo(...) :: ... — extract the function name being spec'd
  defp attribute_target(:spec, [{:"::", _, [{name, _, _args}, _]}]) when is_atom(name), do: name
  defp attribute_target(:type, [{:"::", _, [{name, _, _args}, _]}]) when is_atom(name), do: name
  defp attribute_target(:typep, [{:"::", _, [{name, _, _args}, _]}]) when is_atom(name), do: name
  defp attribute_target(:opaque, [{:"::", _, [{name, _, _args}, _]}]) when is_atom(name), do: name

  defp attribute_target(:impl, [value]) when is_atom(value) or is_boolean(value), do: value
  defp attribute_target(:behaviour, [value]), do: alias_or_atom(value)
  defp attribute_target(_, _), do: nil

  defp range(node) do
    case Sourceror.get_range(node) do
      %Sourceror.Range{start: start_kw, end: end_kw} ->
        %{start: Keyword.get(start_kw, :line), end: Keyword.get(end_kw, :line)}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp snippet(ast) do
    ast |> Macro.to_string() |> String.slice(0, 60)
  rescue
    _ -> "<unprintable>"
  end
end
