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
    * The file is not reformatted. The moved lines are spliced in as
      written, so the diff is exactly the move: no `field :name,
      :string` → `field(:name, :string)` churn from formatter defaults,
      and unrelated code is left untouched.

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
      {:ok, %{diff: Adze.Diff.unified(source, moved), new_source: moved}}
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
      {:ok, v} when is_binary(v) ->
        {:ok, v}

      {:ok, {name, arity}} when is_atom(name) and not is_nil(name) and is_integer(arity) ->
        {:ok, {name, arity}}

      {:ok, other} ->
        {:error, {:bad_opt, key, other}}

      :error ->
        {:error, {:missing_opt, key}}
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

  # Line-based, no reformatting: each `Definition.range` covers whole
  # source lines from the earliest leading comment / attribute to the
  # last clause's `end`, and defs in a module body sit on their own
  # lines with the module's indentation, so cutting and pasting lines is
  # enough.
  #
  # Blank-line separators are handled here rather than by a formatter
  # pass. If the block was blank-separated from its neighbours, one
  # adjacent blank goes with it (the one below, or above when it's the
  # last def) and one is put back below it at the destination. A block
  # in a tight group (`def a, do: 1` / `def b, do: 2`) moves with no
  # blank either way.
  defp perform_move(source, src_def, tgt_def) do
    lines = String.split(source, "\n")

    src_start = src_def.range.start[:line] - 1
    src_end = src_def.range.end[:line] - 1
    tgt_start = tgt_def.range.start[:line] - 1

    block = Enum.slice(lines, src_start..src_end)

    {cut_start, cut_end, separated?} =
      cond do
        blank_at?(lines, src_end + 1) -> {src_start, src_end + 1, true}
        blank_at?(lines, src_start - 1) -> {src_start - 1, src_end, true}
        true -> {src_start, src_end, false}
      end

    cut_len = cut_end - cut_start + 1
    {before_cut, rest} = Enum.split(lines, cut_start)
    remaining = before_cut ++ Enum.drop(rest, cut_len)

    insert_at = if cut_start < tgt_start, do: tgt_start - cut_len, else: tgt_start
    insert = if separated?, do: block ++ [""], else: block

    {pre, post} = Enum.split(remaining, insert_at)
    Enum.join(pre ++ insert ++ post, "\n")
  end

  defp blank_at?(_lines, idx) when idx < 0, do: false

  defp blank_at?(lines, idx) do
    case Enum.at(lines, idx) do
      nil -> false
      line -> String.trim(line) == ""
    end
  end
end
