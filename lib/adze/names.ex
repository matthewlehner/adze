defmodule Adze.Names do
  @moduledoc false
  # The one place user-supplied text may be mapped to an atom, and it
  # never creates one. Atoms are never garbage collected, so turning
  # arbitrary strings into atoms can exhaust the VM's atom table.

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
end
