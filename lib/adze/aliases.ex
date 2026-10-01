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

  alias Adze.Names

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

  defp collect_modules(ast, lines), do: ast |> walk_modules([], "", lines) |> Enum.reverse()

  defp walk_modules({:__block__, _, exprs}, acc, prefix, lines) do
    Enum.reduce(exprs, acc, &walk_modules(&1, &2, prefix, lines))
  end

  defp walk_modules({:defmodule, _meta, [alias_ast, [{_do, body}]]} = node, acc, prefix, lines) do
    name = Adze.Names.defmodule_name(alias_ast, prefix)

    entry = %{
      name: name,
      range: range(node),
      directives: collect_directives(body, name, lines)
    }

    walk_modules(body, [entry | acc], name, lines)
  end

  defp walk_modules(_other, acc, _prefix, _lines), do: acc

  # --- per-module directives ---------------------------------------------

  # `module` is the enclosing module, so `__MODULE__`-based targets resolve.
  defp collect_directives({:__block__, _, exprs}, module, lines),
    do: Enum.flat_map(exprs, &directive_node(&1, module, lines))

  defp collect_directives(expr, module, lines), do: directive_node(expr, module, lines)

  defp directive_node({kind, _meta, args} = node, module, lines) when kind in @directives do
    r = range(node)
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

  defp range(node) do
    case Sourceror.get_range(node) do
      %Sourceror.Range{start: start_kw, end: end_kw} ->
        %{start: Keyword.get(start_kw, :line), end: Keyword.get(end_kw, :line)}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
