defmodule Adze.Extract.Render do
  @moduledoc false
  # Text helpers shared by the target-file and source-file builders:
  # slicing definitions out of the source verbatim, rendering rewritten
  # AST, and the final format pass. Render/format failures are thrown as
  # `{:render, e}` / `{:format, e}` and caught in `Adze.Extract.extract/2`.

  # Skip Sourceror's automatic Mix.Tasks.Format lookup by passing
  # an explicit empty list. Code.format_string! runs afterward with
  # the project's resolved formatter opts (see resolve_formatter_opts/1)
  # and normalizes the result.
  def render_node(node) do
    Sourceror.to_string(node, locals_without_parens: [])
  rescue
    e -> throw({:render, e})
  end

  def slice_node_text(node, source_lines) do
    case Sourceror.get_range(node) do
      nil -> ""
      range -> slice_range_text(range, source_lines)
    end
  end

  def slice_range_text(%{start: s, end: e}, source_lines) do
    start_line = Keyword.fetch!(s, :line) - 1
    end_line = Keyword.fetch!(e, :line) - 1

    source_lines
    |> Enum.slice(start_line..end_line)
    |> Enum.join("\n")
  end

  # `formatter_opts` lets callers pass through the project's
  # `.formatter.exs` configuration (notably `:locals_without_parens`
  # expanded from `:import_deps` — Ecto's `field`, `belongs_to`, `from`;
  # Phoenix's `live_redirect`, etc.). Without that, the formatter
  # parenthesizes every macro call site, producing huge cosmetic diffs
  # that obscure the real edit. `extract_file/2` resolves the right
  # opts via `Mix.Tasks.Format.formatter_for_file/1` when running
  # under `mix adze`; the in-memory `extract/2` path defaults to `[]`.
  def reformat(source, formatter_opts) do
    formatted =
      source
      |> Code.format_string!(formatter_opts)
      |> IO.iodata_to_binary()

    if String.ends_with?(formatted, "\n"), do: formatted, else: formatted <> "\n"
  rescue
    e -> throw({:format, e})
  end
end
