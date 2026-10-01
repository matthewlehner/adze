defmodule Adze.Names do
  @moduledoc false
  # Name handling shared across ops:
  #
  #   * user-supplied names: the one place user text may be mapped to an
  #     atom, and it never creates one. Atoms are never garbage
  #     collected, so turning arbitrary strings into atoms can exhaust
  #     the VM's atom table;
  #   * module names read from source: one set of rules for what a
  #     `defmodule` or `alias` names, so every op agrees.

  @doc """
  The existing atom for `name`, or `name` itself when the VM has no such
  atom. A name with no atom cannot equal any atom produced by parsing
  source that has already been read.
  """
  @spec existing_atom_or_string(String.t()) :: atom() | String.t()
  def existing_atom_or_string(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  @doc "True when a parsed atom `name` equals a target that may be an atom or a string."
  @spec name_matches?(atom() | String.t(), atom()) :: boolean()
  def name_matches?(wanted, name) when is_atom(wanted), do: wanted == name
  def name_matches?(wanted, name) when is_binary(wanted), do: wanted == Atom.to_string(name)

  # `String.to_atom/1` raises past 255 characters; the cap keeps a module
  # name from doing that and bounds what one call can intern.
  @max_module_name_bytes 200

  @doc """
  True for a well-formed `Foo.Bar` module name short enough to become an atom.
  """
  @spec valid_module_name?(term()) :: boolean()
  def valid_module_name?(name) when is_binary(name) do
    byte_size(name) <= @max_module_name_bytes and
      Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/, name)
  end

  def valid_module_name?(_), do: false

  @doc """
  The full name of the module a `defmodule` defines, given the name of
  the enclosing module (`""` at the top level). Follows Elixir's rules:

    * a plain alias nests: `defmodule Inner` in `Foo` is `Foo.Inner`;
    * `__MODULE__.Inner` is already absolute: `Foo.Inner`, not
      `Foo.Foo.Inner`;
    * anything else (an atom, an expression, `__MODULE__` at the top
      level) is labelled as written via `module_expr_label/1`.
  """
  @spec defmodule_name(Macro.t(), String.t()) :: String.t()
  def defmodule_name({:__aliases__, _, parts} = ast, enclosing) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1),
      do: qualify(enclosing, join_atoms(parts)),
      else: module_ref(ast, enclosing)
  end

  def defmodule_name(ast, enclosing), do: module_ref(ast, enclosing)

  @doc """
  The module a reference (an `alias`/`import`/`use` target, an `as:`)
  names, from inside module `current` (`""` at the top level). Plain
  aliases are taken as written, a leading `__MODULE__` is replaced with
  `current`, and anything that can't be resolved is labelled as written.
  """
  @spec module_ref(Macro.t(), String.t()) :: String.t()
  def module_ref({:__MODULE__, _, ctx}, current) when is_atom(ctx) and current != "",
    do: current

  def module_ref({:__aliases__, _, [{:__MODULE__, _, ctx} | rest]} = ast, current)
      when is_atom(ctx) and current != "" do
    if Enum.all?(rest, &is_atom/1),
      do: qualify(current, join_atoms(rest)),
      else: module_expr_label(ast)
  end

  def module_ref({:__aliases__, _, parts} = ast, _current) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: join_atoms(parts), else: module_expr_label(ast)
  end

  def module_ref(ast, _current), do: module_expr_label(ast)

  @doc """
  A readable label for a module name that isn't a plain alias: an atom
  (`:my_mod`) or an expression (`Module.concat([:a])`), rendered as
  written. Such labels never pass `valid_module_name?/1`, so they can't be
  mistaken for a real `Foo.Bar` module.
  """
  @spec module_expr_label(Macro.t()) :: String.t()
  def module_expr_label(atom) when is_atom(atom), do: inspect(atom)
  def module_expr_label({:__block__, _, [atom]}) when is_atom(atom), do: inspect(atom)
  def module_expr_label(ast), do: Sourceror.to_string(ast)

  defp qualify("", name), do: name
  defp qualify(prefix, ""), do: prefix
  defp qualify(prefix, name), do: prefix <> "." <> name

  defp join_atoms([]), do: ""
  defp join_atoms(parts), do: parts |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
end
