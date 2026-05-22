defmodule Adze.Move do
  @moduledoc """
  `mv` — reorder a logical definition within a single file.

  Moves a `def` (with its attached `@spec`/`@doc`/leading comments and
  every clause — i.e. the whole `Adze.Definition` group) to just before
  another `def` in the same module.

  Scope:

    * Single file, single module. Both `--definition` and `--before` must
      resolve to defs in the same `defmodule`. Cross-module moves are
      explicitly out of scope — that's `extract`'s job.
    * `--before` is the only supported anchor (no `--after`).
    * `mv/2` is pure (returns the diff + new source). `mv!/2` writes the
      file.

  ## Usage

      iex> Adze.Move.mv(source, definition: "bar/2", before: "baz/1")
      {:ok, %{diff: "...", new_source: "..."}}

      Adze.Move.mv!("lib/foo.ex", definition: "bar/2", before: "baz/1")
      # → {:ok, %{diff: ..., new_source: ...}}  +  rewrites lib/foo.ex
  """

  alias Adze.Definition

  @type opts :: [
          definition: Definition.definition_spec(),
          before: Definition.definition_spec(),
          include_attrs: [atom()]
        ]

  @type result :: %{diff: String.t(), new_source: String.t()}

  @spec mv(String.t(), opts()) :: {:ok, result()} | {:error, term()}
  def mv(source, opts) when is_binary(source) and is_list(opts) do
    with {:ok, def_spec} <- fetch_opt(opts, :definition),
         {:ok, before_spec} <- fetch_opt(opts, :before),
         {:ok, src_def} <- find_labeled(source, def_spec, opts, :definition),
         {:ok, tgt_def} <- find_labeled(source, before_spec, opts, :before),
         :ok <- check_not_self(src_def, tgt_def),
         :ok <- check_same_module(src_def, tgt_def) do
      moved = perform_move(source, src_def, tgt_def)
      formatted = reformat(moved)
      {:ok, %{diff: Adze.Diff.unified(source, formatted), new_source: formatted}}
    end
  end

  @spec mv_file(Path.t(), opts()) :: {:ok, result()} | {:error, term()}
  def mv_file(path, opts) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> mv(source, opts)
      {:error, reason} -> {:error, {:file_read, reason}}
    end
  end

  @spec mv!(Path.t(), opts()) :: {:ok, result()} | {:error, term()}
  def mv!(path, opts) when is_binary(path) do
    with {:ok, result} <- mv_file(path, opts) do
      case File.write(path, result.new_source) do
        :ok -> {:ok, result}
        {:error, reason} -> {:error, {:file_write, reason}}
      end
    end
  end

  # --- option handling ---------------------------------------------------

  defp find_labeled(source, spec, opts, label) do
    case Definition.find(source, spec, opts) do
      {:ok, d} -> {:ok, d}
      {:error, :not_found} -> {:error, {:not_found, label}}
      {:error, _} = err -> err
    end
  end

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, v} when is_binary(v) -> {:ok, v}
      {:ok, {name, arity}} when is_atom(name) and is_integer(arity) -> {:ok, {name, arity}}
      {:ok, other} -> {:error, {:bad_opt, key, other}}
      :error -> {:error, {:missing_opt, key}}
    end
  end

  defp check_not_self(%Definition{} = src, %Definition{} = tgt) do
    if src.module == tgt.module and src.name == tgt.name and src.arity == tgt.arity do
      {:error, :self_anchor}
    else
      :ok
    end
  end

  defp check_same_module(%Definition{module: m}, %Definition{module: m}), do: :ok

  defp check_same_module(%Definition{} = src, %Definition{} = tgt) do
    {:error,
     {:cross_module_move,
      %{
        definition: {src.name, src.arity},
        definition_module: src.module,
        before: {tgt.name, tgt.arity},
        before_module: tgt.module
      }}}
  end

  # --- move (line-based slice/cut/paste) ---------------------------------

  defp perform_move(source, src_def, tgt_def) do
    # Line-based: each Definition.range covers full source lines from the
    # earliest leading comment to the last clause's `end`. Defs live on
    # their own lines inside a defmodule body, so slicing by line is
    # both simpler than Sourceror.Patch and includes the right
    # whitespace/indentation for the paste.
    #
    # We extend the slice to also grab the conventional blank line that
    # follows a def. Without that the cut/paste destroys blank separators
    # between adjacent defs and the formatter can't restore them.
    lines = String.split(source, "\n")

    raw_src_start = src_def.range.start[:line] - 1
    raw_src_end = src_def.range.end[:line] - 1
    tgt_start = tgt_def.range.start[:line] - 1

    src_end = extend_trailing_blank(lines, raw_src_end)
    block_len = src_end - raw_src_start + 1

    src_lines = Enum.slice(lines, raw_src_start..src_end)

    {before_src, rest} = Enum.split(lines, raw_src_start)
    {_dropped, after_src} = Enum.split(rest, block_len)
    cut = before_src ++ after_src

    adjusted_tgt =
      if raw_src_start < tgt_start, do: tgt_start - block_len, else: tgt_start

    {pre, post} = Enum.split(cut, adjusted_tgt)
    Enum.join(pre ++ src_lines ++ post, "\n")
  end

  defp extend_trailing_blank(lines, end_idx) do
    case Enum.at(lines, end_idx + 1) do
      nil -> end_idx
      line -> if blank?(line), do: end_idx + 1, else: end_idx
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  defp reformat(source) do
    formatted =
      source
      |> Code.format_string!()
      |> IO.iodata_to_binary()

    if String.ends_with?(formatted, "\n"), do: formatted, else: formatted <> "\n"
  end
end
