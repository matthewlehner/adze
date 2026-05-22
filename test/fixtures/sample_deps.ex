defmodule SampleDeps do
  @moduledoc false

  def main(x) do
    x
    |> double()
    |> add_one()
    |> finalize()
  end

  def add_one(x), do: x + 1
  def add_one(x, n) when is_integer(n), do: x + n

  defp double(x), do: x * 2

  defp finalize(x) do
    log(x)
    helper(x, :default)
    External.thing(x)
    Enum.map([x], &double/1)
    x
  end

  defp helper(x, mode \\ :normal) do
    log({x, mode})
    x
  end

  defp log(msg) do
    IO.inspect(msg)
  end
end

defmodule SampleDeps.Sibling do
  def go, do: :ok
end
