defmodule Adze.AliasScope do
  @moduledoc false
  # Elixir's lexical alias rules, shared by every walk that has to know
  # what a short name like `Foo` refers to at a given point
  # (`Adze.FindCallers`, the rename short-ref fix-up in
  # `Adze.ProjectRewrite`):
  #
  #   * an `alias` holds until the end of the construct it's declared
  #     in — the module body, a `def`, a do-block (`if`, `for`, `test`,
  #     ...) or a `->` clause (`fn`, `case`, ...). `scope_node?/1` tells
  #     a walker when to save and restore its alias table;
  #   * `defmodule Inner` nested in `Outer` aliases `Inner` →
  #     `Outer.Inner` in the enclosing scope (`implicit_alias/3`);
  #   * `alias_bindings/2` reads what names an `alias` declaration binds.

  alias Adze.Names

  @type binding :: %{name: String.t(), module: String.t(), as?: boolean()}

  @doc """
  True for nodes that open a lexical alias scope: a `->` clause, or any
  call carrying a `do` block / `do:` keyword (`def`, `if`, `case`, `for`,
  `with`, `try`, `receive`, `test`, ...). `defmodule` also matches;
  walkers that track module names handle it before asking.
  """
  @spec scope_node?(Macro.t()) :: boolean()
  def scope_node?({:->, _, _}), do: true

  def scope_node?({_form, _, args}) when is_list(args) and args != [] do
    case List.last(args) do
      kw when is_list(kw) -> Enum.any?(kw, &do_entry?/1)
      _ -> false
    end
  end

  def scope_node?(_), do: false

  defp do_entry?({key, _body}), do: unwrap_atom(key) == :do
  defp do_entry?(_), do: false

  @doc """
  The alias a nested `defmodule` adds to its enclosing scope, as
  `{name, module}`, or `nil`. `defmodule Foo.Bar` inside `Outer`
  defines `Outer.Foo.Bar` and aliases the first segment, `Foo` →
  `Outer.Foo`. Top-level and `__MODULE__`-prefixed names add none, and
  neither does a name whose first segment is already an alias
  (`head_bound?`) — Elixir expands it through that alias instead of
  nesting.
  """
  @spec implicit_alias(Macro.t(), String.t() | nil, boolean()) ::
          {String.t(), String.t()} | nil
  def implicit_alias({:__aliases__, _, [first | _]}, current, false = _head_bound?)
      when is_atom(first) and is_binary(current) do
    name = Atom.to_string(first)
    {name, current <> "." <> name}
  end

  def implicit_alias(_alias_ast, _current, _head_bound?), do: nil

  @doc """
  The names an `alias` declaration's `args` bind, from inside module
  `current` (`nil` at the top level). Targets are taken as written (a
  leading `__MODULE__` is substituted); targets that can't be resolved
  statically bind nothing.

      alias Foo.Bar               → [%{name: "Bar", module: "Foo.Bar", as?: false}]
      alias Foo.Bar, as: B        → [%{name: "B",   module: "Foo.Bar", as?: true}]
      alias Foo.{A, B.C}          → A → Foo.A, C → Foo.B.C
      alias __MODULE__            → last segment of `current`
  """
  @spec alias_bindings(list(), String.t() | nil) :: [binding()]
  def alias_bindings([{{:., _, [base, :{}]}, _, members}], current) when is_list(members) do
    case resolve(base, current) do
      nil ->
        []

      base_name ->
        Enum.flat_map(members, fn
          {:__aliases__, _, parts} = member when is_list(parts) ->
            if Enum.all?(parts, &is_atom/1),
              do: [binding(base_name <> "." <> Names.module_ref(member, ""), nil)],
              else: []

          _ ->
            []
        end)
    end
  end

  def alias_bindings([target], current), do: alias_bindings([target, []], current)

  def alias_bindings([target, opts], current) when is_list(opts) do
    case resolve(target, current) do
      nil -> []
      module -> [binding(module, as_name(opts))]
    end
  end

  def alias_bindings(_args, _current), do: []

  defp binding(module, nil),
    do: %{name: module |> String.split(".") |> List.last(), module: module, as?: false}

  defp binding(module, as), do: %{name: as, module: module, as?: true}

  defp resolve(ast, current) do
    name = Names.module_ref(ast, current || "")
    if Names.valid_module_name?(name), do: name, else: nil
  end

  defp as_name(opts) do
    Enum.find_value(opts, fn
      {key, {:__aliases__, _, [as]}} when is_atom(as) ->
        if unwrap_atom(key) == :as, do: Atom.to_string(as)

      _ ->
        nil
    end)
  end

  defp unwrap_atom({:__block__, _, [a]}) when is_atom(a), do: a
  defp unwrap_atom(a) when is_atom(a), do: a
  defp unwrap_atom(_), do: nil
end
