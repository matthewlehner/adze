defmodule Adze.Aliases do
  @moduledoc """
  List every `alias` / `import` / `require` / `use` directive in a file,
  scoped per `defmodule` and emitted in source order.

  Useful as a cleanup target (unused aliases, `import` -> explicit
  `alias`, etc.) and as a navigation index for AI consumers — same role
  as `outline`, but specifically for directives.

  ## Output shape

      %{
        file: "lib/foo.ex" | nil,
        modules: [
          %{
            name: "Foo.Bar",
            range: %{start: 1, end: 20},
            directives: [
              %{
                kind: :alias | :import | :require | :use,
                target: "Foo.Bar",           # dotted module string
                as: "Baz" | nil,             # alias-only binding override
                group: true | false,         # part of `alias Foo.{A, B}` form
                text: "alias Foo.Bar",       # raw source slice
                range: %{start: N, end: N}
              },
              ...
            ]
          }
        ]
      }

  Group-form `alias Foo.{A, B}` is expanded into one entry per member.
  All members share the same `range` and `text` (pointing at the
  original declaration) and carry `group: true`, so callers can either
  reason about each binding independently or recognize the original
  grouping.
  """

  alias Adze.{AST, Names}

  @directives [:alias, :import, :require, :use]

  @type directive :: %{
          kind: :alias | :import | :require | :use,
          target: String.t(),
          as: String.t() | nil,
          group: boolean(),
          text: String.t(),
          range: %{start: pos_integer(), end: pos_integer()} | nil
        }

  @spec aliases_file(Path.t()) :: {:ok, map()} | {:error, term()}
  def aliases_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> aliases(source, file: path)
      {:error, reason} -> {:error, {:file_read, reason}}
    end
  end

  @spec aliases(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def aliases(source, opts \\ []) when is_binary(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        lines = String.split(source, "\n")

        {:ok,
         %{
           file: Keyword.get(opts, :file),
           modules: collect_modules(ast, lines)
         }}

      {:error, reason} ->
        {:error, {:parse, reason}}
    end
  end

  # --- module discovery (same shape as Adze.Deps) ------------------------

  defp collect_modules(ast, lines) do
    ast
    |> AST.reduce_modules([], fn node, name, body, acc ->
      entry = %{
        name: name,
        range: AST.line_range(node),
        directives: collect_directives(body, name, lines)
      }

      [entry | acc]
    end)
    |> Enum.reverse()
  end

  # --- per-module directives ---------------------------------------------

  # `module` is the enclosing module, so `__MODULE__`-based targets resolve.
  defp collect_directives({:__block__, _, exprs}, module, lines),
    do: Enum.flat_map(exprs, &directive_node(&1, module, lines))

  defp collect_directives(expr, module, lines), do: directive_node(expr, module, lines)

  defp directive_node({kind, _meta, args} = node, module, lines) when kind in @directives do
    r = AST.line_range(node)
    expand_directive(kind, args, module, r, source_slice(lines, r))
  end

  defp directive_node(_, _module, _lines), do: []

  # alias Foo.{A, B, C.D}  →  one entry per member, all sharing the
  # original line range + text + group: true.
  defp expand_directive(:alias, [{{:., _, [base, :{}]}, _, members}], module, r, text) do
    base_str = Names.module_ref(base, module)

    Enum.map(members, fn member ->
      %{
        kind: :alias,
        target: base_str <> "." <> Names.module_ref(member, ""),
        as: nil,
        group: true,
        text: text,
        range: r
      }
    end)
  end

  # alias/import/require/use Mod
  defp expand_directive(kind, [target], module, r, text) do
    [
      %{
        kind: kind,
        target: Names.module_ref(target, module),
        as: nil,
        group: false,
        text: text,
        range: r
      }
    ]
  end

  # alias Mod, as: Other  /  import Mod, only: [...]  /  use Mod, opt: val
  defp expand_directive(kind, [target, kw], module, r, text) do
    [
      %{
        kind: kind,
        target: Names.module_ref(target, module),
        as: if(kind == :alias, do: extract_as(kw), else: nil),
        group: false,
        text: text,
        range: r
      }
    ]
  end

  defp expand_directive(_kind, _args, _module, _r, _text), do: []

  defp extract_as(kw) when is_list(kw) do
    Enum.find_value(kw, fn
      {{:__block__, _, [:as]}, alias_ast} -> Names.module_ref(alias_ast, "")
      {:as, alias_ast} -> Names.module_ref(alias_ast, "")
      _ -> nil
    end)
  end

  defp extract_as(_), do: nil

  # --- helpers -----------------------------------------------------------

  defp source_slice(_lines, nil), do: ""

  defp source_slice(lines, %{start: s, end: e}) do
    lines
    |> Enum.slice((s - 1)..(e - 1))
    |> Enum.join("\n")
    |> String.trim_leading()
  end
end
