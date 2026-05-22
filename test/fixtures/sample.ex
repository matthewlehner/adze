defmodule Sample do
  @moduledoc """
  A fixture exercising many top-level shapes.
  """

  use GenServer
  alias Sample.Inner
  import Enum, only: [map: 2]
  require Logger

  @behaviour GenServer
  @some_attr 42

  defstruct [:id, :name, count: 0]

  @spec greet(String.t()) :: String.t()
  def greet(name) when is_binary(name) do
    "hello, " <> name
  end

  def greet(_), do: "hello, stranger"

  defp internal(x), do: x * 2

  defmacro debug(expr) do
    quote do
      IO.inspect(unquote(expr))
    end
  end

  defguard is_pos(n) when is_integer(n) and n > 0

  defdelegate child_call(x), to: Inner

  defmodule Inner do
    @moduledoc false
    def hello, do: :world
    defp helper(_), do: :ok
  end
end

defprotocol Sample.Stringer do
  @doc "Render anything as a string"
  def to_str(value)
end

defimpl Sample.Stringer, for: Integer do
  def to_str(i), do: Integer.to_string(i)
end
