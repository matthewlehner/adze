defmodule Adze.Rename do
  @moduledoc """
  `rename` / `rename!` — globally rename a module across the project.

  Wraps `Igniter.Refactors.Rename.rename_module/3` via
  `Adze.ProjectRewrite`. Updates `defmodule`, every `alias` /
  `use` / `import` / `require`, all call sites, the corresponding test
  module (if any), and string literals mentioning the module. The
  module's file is moved to its canonical location (derived from the
  new name).

  ## CLI

      mix adze rename  --from MyApp.Old --to MyApp.New
      mix adze rename! --from MyApp.Old --to MyApp.New

  Dry-run by default: prints a diff for every touched file. `rename!`
  also writes.

  ## Programmatic

      Adze.Rename.rename(from: "MyApp.Old", to: "MyApp.New")
      #=> {:ok, %{diffs: %{path => diff}, moves: %{old_path => new_path},
      #          warnings: [...], notices: [...]}}

      Adze.Rename.rename!(from: "MyApp.Old", to: "MyApp.New")

  Both accept `mix_root:` (defaults to the current directory) and
  `files:` for in-memory test fixtures (delegates to
  `Adze.ProjectRewrite.new/1`).

  ## Short-ref fix-up

  When Igniter's same-namespace rename leaves bare `OldShort.fun(...)`
  call sites un-rewritten (an upstream bug — string substitution
  rewrites the alias declaration before the AST pass runs, so bare
  refs no longer resolve back to the old aliases list), adze patches
  them itself in files that had a non-`as:` alias to the renamed
  module. Patched locations come back as `{:rewritten_short_refs,
  refs}` in `notices:`. Locations that couldn't be safely patched (no
  qualifying alias declaration in pre-rewrite content) come back as
  `{:surviving_references, refs}` in `warnings:`, and `rename!/1`
  refuses to write unless `force: true`.

  ## Limitations (inherited from Igniter)

    * Dynamic refs (`apply/3`, `Module.concat/2` with variables) are
      not rewritten.
    * `alias Foo.Old, as: B` keeps the `as:` binding; only the alias
      declaration is updated. `B.*` call sites are correct since they
      resolve through `as:`.
    * String-literal substitution is a plain substring replace over
      raw file content — it also rewrites occurrences inside comments
      and unrelated strings. Grep after.
  """

  alias Adze.ProjectRewrite

  @type opts :: [
          from: String.t() | module(),
          to: String.t() | module(),
          mix_root: Path.t(),
          files: %{Path.t() => String.t()},
          app_name: atom(),
          force: boolean()
        ]

  @type result :: %{
          from: module(),
          to: module(),
          diffs: %{Path.t() => String.t()},
          moves: %{Path.t() => Path.t()},
          warnings: list(),
          notices: list()
        }

  @spec rename(opts()) :: {:ok, result()} | {:error, term()}
  def rename(opts) when is_list(opts) do
    with {:ok, ctx} <- build(opts) do
      {:ok, build_result(ctx)}
    end
  end

  @spec rename!(opts()) :: {:ok, result()} | {:error, term()}
  def rename!(opts) when is_list(opts) do
    force? = Keyword.get(opts, :force, false)

    with {:ok, ctx} <- build(opts),
         :ok <- guard_surviving(ctx.report.surviving_refs, force?),
         :ok <- ProjectRewrite.write(ctx.rewrite) do
      {:ok, build_result(ctx)}
    end
  end

  # Build the rewrite, run the rename (which now also handles the
  # short-ref fix-up internally), and dry-run-shape the result. Shared
  # by rename/1 and rename!/1 so they can't disagree on what was found.
  defp build(opts) do
    with {:ok, from} <- fetch_module(opts, :from),
         {:ok, to} <- fetch_module(opts, :to),
         :ok <- validate_distinct(from, to),
         {:ok, rewrite} <- ProjectRewrite.new(opts),
         {:ok, rewrite, report} <- ProjectRewrite.rename_module(rewrite, from, to),
         {:ok, dry} <- ProjectRewrite.result(rewrite) do
      case dry.issues do
        [] ->
          {:ok, %{from: from, to: to, rewrite: rewrite, dry: dry, report: report}}

        issues ->
          {:error, {:issues, issues}}
      end
    end
  end

  defp build_result(ctx) do
    extra_warnings =
      case ctx.report.surviving_refs do
        [] -> []
        refs -> [{:surviving_references, refs}]
      end

    extra_notices =
      case ctx.report.fixed_refs do
        [] -> []
        refs -> [{:rewritten_short_refs, refs}]
      end

    %{
      from: ctx.from,
      to: ctx.to,
      diffs: ctx.dry.diffs,
      moves: ctx.dry.moves,
      warnings: ctx.dry.warnings ++ extra_warnings,
      notices: ctx.dry.notices ++ extra_notices
    }
  end

  defp guard_surviving([], _force?), do: :ok
  defp guard_surviving(_refs, true), do: :ok
  defp guard_surviving(refs, false), do: {:error, {:surviving_references, refs}}

  # --- option parsing ----------------------------------------------------

  defp fetch_module(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> {:error, {:missing_opt, key}}
      {:ok, nil} -> {:error, {:missing_opt, key}}
      {:ok, mod} when is_atom(mod) -> {:ok, mod}
      {:ok, str} when is_binary(str) -> parse_module(str, key)
      {:ok, other} -> {:error, {:bad_opt, key, other}}
    end
  end

  defp parse_module(str, key) do
    if Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/, str) do
      {:ok, Module.concat([str])}
    else
      {:error, {:bad_module_name, key, str}}
    end
  end

  defp validate_distinct(m, m), do: {:error, {:same_module, m}}
  defp validate_distinct(_, _), do: :ok
end
