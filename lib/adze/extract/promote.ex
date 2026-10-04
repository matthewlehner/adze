defmodule Adze.Extract.Promote do
  @moduledoc false
  # Making private definitions public when extract needs them to be: a
  # private target becomes the new module's entry point, and private
  # helpers that stay in the source but are called from the target are
  # reached remotely. Both get the public kind and `@doc false`.

  alias Adze.Definition

  @promotions %{defp: :def, defmacrop: :defmacro, defguardp: :defguard}

  # Flip the target definition to its public kind when it's private.
  # Returns the updated closure list and the list of promoted keys
  # (empty or a single element — only the target can be promoted).
  def promote_target(closure_defs, {name, arity}) do
    Enum.map_reduce(closure_defs, [], fn
      %Definition{name: ^name, arity: ^arity, visibility: :private, kind: kind} = d, acc
      when is_map_key(@promotions, kind) ->
        {promote_definition(d), [{name, arity} | acc]}

      d, acc ->
        {d, acc}
    end)
  end

  # Flip a private definition's AST kind (`defp` → `def`, etc.).
  def promote_definition(%Definition{kind: kind} = d) do
    new_kind = Map.fetch!(@promotions, kind)

    flip = fn
      {^kind, m, args} -> {new_kind, m, args}
      other -> other
    end

    %{
      d
      | kind: new_kind,
        visibility: :public,
        nodes: Enum.map(d.nodes, flip),
        parts: %{d.parts | clauses: Enum.map(d.parts.clauses, flip)}
    }
  end

  # The slice-render path copies source text verbatim, so the private
  # keyword survives there. Flip it on exactly the clause start lines
  # (mirrors Adze.ExtractPrivate.flip_clauses/3 in the other direction)
  # rather than regexing the whole block — a `defp` inside a `quote`
  # body must be left alone.
  def flip_private_keyword_in_text(text, %Definition{} = d) do
    first_line = Keyword.fetch!(d.range.start, :line)

    clause_offsets =
      d.parts.clauses
      |> Enum.map(fn clause ->
        case Sourceror.get_range(clause) do
          %{start: s} -> Keyword.get(s, :line) - first_line
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    pattern = ~r/^(\s*)(defp|defmacrop|defguardp)(\s)/

    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      if MapSet.member?(clause_offsets, idx) do
        Regex.replace(pattern, line, fn _, indent, kw, ws ->
          indent <> Atom.to_string(Map.fetch!(@promotions, String.to_atom(kw))) <> ws
        end)
      else
        line
      end
    end)
    |> Enum.join("\n")
  end

  # `@doc false` marks the promoted def as public-for-structure, not
  # API. Skip when the author already wrote a `@doc` (true, false, or
  # a docstring) — theirs wins.
  def prepend_doc_false(text, %Definition{parts: %{attributes: attrs}}) do
    if Enum.any?(attrs, fn {attr_name, _} -> attr_name == :doc end) do
      text
    else
      indent =
        case Regex.run(~r/^(\s*)\S/, text) do
          [_, i] -> i
          _ -> ""
        end

      # Insert below any leading comment lines so the comment stays
      # attached to the `@doc` / def it describes.
      {comments, rest} =
        text
        |> String.split("\n")
        |> Enum.split_while(&String.starts_with?(String.trim_leading(&1), "#"))

      Enum.join(comments ++ [indent <> "@doc false" | rest], "\n")
    end
  end
end
