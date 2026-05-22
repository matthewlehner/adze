defmodule Adze.Diff do
  @moduledoc """
  Line-based unified diff for write-op dry-runs.

  Used by `Adze.Move`, `Adze.Extract`, and `Adze.ExtractPrivate` to
  render the human-/AI-readable preview of a write. Standard unified
  format with `--- a` / `+++ b` headers, `@@ -a,n +b,m @@` hunks, and
  3 lines of context. Empty string when the inputs are identical.
  """

  @context 3

  @doc """
  Build a unified diff between two strings. Returns `""` when they're
  identical line-for-line; otherwise an `iodata`-flattened string with
  `--- a` / `+++ b` headers and one or more hunks.
  """
  @spec unified(String.t(), String.t()) :: String.t()
  def unified(before, after_) do
    a = split_lines(before)
    b = split_lines(after_)

    case List.myers_difference(a, b) do
      [{:eq, _}] ->
        ""

      diff ->
        entries = annotate(diff)
        hunks = build_hunks(entries, @context)

        IO.iodata_to_binary([
          "--- a\n",
          "+++ b\n",
          Enum.map(hunks, &render_hunk/1)
        ])
    end
  end

  # `String.split(s, "\n")` produces a trailing "" when `s` ends in "\n".
  # That trailing empty appears as :eq on both sides so it doesn't show
  # up as noise — keep it.
  defp split_lines(s), do: String.split(s, "\n")

  # Flatten the myers chunks into per-line entries:
  # `{a_line_no, b_line_no, :eq | :del | :ins, text}`. Line numbers are
  # 1-indexed; `nil` when the line doesn't exist on that side.
  defp annotate(diff) do
    {_, _, acc} =
      Enum.reduce(diff, {1, 1, []}, fn
        {:eq, ls}, {a, b, acc} ->
          {a + length(ls), b + length(ls),
           acc ++ Enum.with_index(ls, fn l, i -> {a + i, b + i, :eq, l} end)}

        {:del, ls}, {a, b, acc} ->
          {a + length(ls), b,
           acc ++ Enum.with_index(ls, fn l, i -> {a + i, nil, :del, l} end)}

        {:ins, ls}, {a, b, acc} ->
          {a, b + length(ls),
           acc ++ Enum.with_index(ls, fn l, i -> {nil, b + i, :ins, l} end)}
      end)

    acc
  end

  defp build_hunks(entries, context) do
    indices =
      entries
      |> Enum.with_index()
      |> Enum.filter(fn {{_, _, k, _}, _} -> k != :eq end)
      |> Enum.map(&elem(&1, 1))

    case indices do
      [] ->
        []

      _ ->
        total = length(entries)

        ranges =
          indices
          |> Enum.reduce([], fn i, acc ->
            lo = max(0, i - context)
            hi = min(total - 1, i + context)

            case acc do
              [{plo, phi} | rest] when lo <= phi + 1 ->
                [{plo, max(phi, hi)} | rest]

              _ ->
                [{lo, hi} | acc]
            end
          end)
          |> Enum.reverse()

        Enum.map(ranges, fn {lo, hi} -> Enum.slice(entries, lo..hi) end)
    end
  end

  defp render_hunk(slice) do
    a_lines = Enum.filter(slice, fn {a, _, _, _} -> a != nil end)
    b_lines = Enum.filter(slice, fn {_, b, _, _} -> b != nil end)

    a_start = hunk_start(a_lines, fn {a, _, _, _} -> a end)
    b_start = hunk_start(b_lines, fn {_, b, _, _} -> b end)

    header = [
      "@@ -",
      Integer.to_string(a_start),
      ",",
      Integer.to_string(length(a_lines)),
      " +",
      Integer.to_string(b_start),
      ",",
      Integer.to_string(length(b_lines)),
      " @@\n"
    ]

    body =
      Enum.map(slice, fn
        {_, _, :eq, l} -> [" ", l, "\n"]
        {_, _, :del, l} -> ["-", l, "\n"]
        {_, _, :ins, l} -> ["+", l, "\n"]
      end)

    [header | body]
  end

  defp hunk_start([], _f), do: 0
  defp hunk_start([first | _], f), do: f.(first)
end
