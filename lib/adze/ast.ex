defmodule Adze.AST do
  @moduledoc false
  # Small Sourceror-AST helpers shared across ops: line ranges, unwrapping
  # Sourceror's literal blocks, and walking `defmodule`s with their full
  # names (resolved via `Adze.Names.defmodule_name/2`).
  #
  # Module walks only descend through a `defmodule`'s body and top-level
  # `__block__`s, so a `defmodule` nested inside another expression
  # (`if`, `quote`, a function body) isn't visited. Every op shares that
  # rule so they agree on which modules a file defines.

  @type line_range :: %{start: pos_integer(), end: pos_integer()}

  @doc "The start/end lines of `node`, or nil when Sourceror can't compute them."
  @spec line_range(Macro.t()) :: line_range() | nil
  def line_range(node) do
    case Sourceror.get_range(node) do
      %Sourceror.Range{start: start_kw, end: end_kw} ->
        %{start: Keyword.get(start_kw, :line), end: Keyword.get(end_kw, :line)}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc """
  The atom in a literal, unwrapping Sourceror's `{:__block__, _, [atom]}`
  wrapper; nil for anything that isn't an atom literal.
  """
  @spec unwrap_atom(Macro.t()) :: atom() | nil
  def unwrap_atom({:__block__, _, [a]}) when is_atom(a), do: a
  def unwrap_atom(a) when is_atom(a), do: a
  def unwrap_atom(_), do: nil

  @doc """
  The names an `alias` directive binds, given its arguments:
  `alias Foo.Bar` → `[:Bar]`, `alias Foo.Bar, as: Baz` → `[:Baz]`,
  `alias Foo.{Bar, Baz}` → `[:Bar, :Baz]`. `[]` for anything else.
  """
  @spec alias_bindings([Macro.t()]) :: [atom()]
  def alias_bindings([{:__aliases__, _, parts} | rest]) do
    case alias_as(rest) do
      {:__aliases__, _, [as_atom]} -> [as_atom]
      _ -> [List.last(parts)]
    end
  end

  def alias_bindings([{{:., _, [{:__aliases__, _, _prefix}, :{}]}, _, members}]) do
    Enum.flat_map(members, fn
      {:__aliases__, _, parts} -> [List.last(parts)]
      _ -> []
    end)
  end

  def alias_bindings(_), do: []

  @doc """
  The `as:` value in an `alias` directive's trailing options, or nil.
  Sourceror wraps keyword keys in `{:__block__, _, [:key]}`, so this
  unwraps each key rather than using `Keyword.get/2`.
  """
  @spec alias_as([Macro.t()]) :: Macro.t() | nil
  def alias_as([opts]) when is_list(opts) do
    Enum.find_value(opts, fn
      {key, value} -> if unwrap_atom(key) == :as, do: value
      _ -> nil
    end)
  end

  def alias_as(_), do: nil

  @doc "The expressions in a `do` body: a block's children, `[]` for nil, else `[body]`."
  @spec body_exprs(Macro.t()) :: [Macro.t()]
  def body_exprs({:__block__, _, exprs}) when is_list(exprs), do: exprs
  def body_exprs(nil), do: []
  def body_exprs(single), do: [single]

  @doc """
  Folds over every `defmodule` in `ast`, outer modules before the modules
  nested inside them, in source order. `fun` receives the `defmodule`
  node, its full name, its body and the accumulator.
  """
  @spec reduce_modules(Macro.t(), acc, (Macro.t(), String.t(), Macro.t(), acc -> acc)) :: acc
        when acc: term()
  def reduce_modules(ast, acc, fun), do: reduce_modules(ast, "", acc, fun)

  defp reduce_modules({:__block__, _, exprs}, prefix, acc, fun) when is_list(exprs),
    do: Enum.reduce(exprs, acc, &reduce_modules(&1, prefix, &2, fun))

  defp reduce_modules({:defmodule, _, [name_ast, [{_do, body}]]} = node, prefix, acc, fun) do
    name = Adze.Names.defmodule_name(name_ast, prefix)
    reduce_modules(body, name, fun.(node, name, body, acc), fun)
  end

  defp reduce_modules(_other, _prefix, acc, _fun), do: acc

  @doc "The first `defmodule` named `target`, as `{node, body}`, or nil."
  @spec find_module(Macro.t(), String.t()) :: {Macro.t(), Macro.t()} | nil
  def find_module(ast, target) do
    ast
    |> reduce_modules(nil, fn
      node, ^target, body, nil -> {node, body}
      _node, _name, _body, acc -> acc
    end)
  end
end
