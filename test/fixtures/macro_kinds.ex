defmodule MacroKinds do
  defmacro pub_macro(x), do: quote(do: unquote(x) + 1)
  defmacrop priv_macro(x), do: quote(do: unquote(x) + 2)
  defguard pub_guard(x) when is_integer(x)
  defguardp priv_guard(x) when is_atom(x)

  def use_them(a, b) when pub_guard(a) and priv_guard(b) do
    pub_macro(a) + priv_macro(b)
  end
end
