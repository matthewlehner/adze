defmodule Mix.Tasks.Adze.Upgrade do
  @shortdoc "Upgrades adze's agent files; run by `mix igniter.upgrade adze`"

  @moduledoc """
  #{@shortdoc}

  Don't call this directly: `mix igniter.upgrade adze` runs it with the
  old and new versions after updating the dependency.

  Every upgrade re-runs `mix adze.install`, which refreshes the skill files
  and the adze section of `AGENTS.md`. Upgrades that change how adze is
  used also point out anything in your own files that needs updating.
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :adze,
      positional: [:from, :to],
      composes: ["adze.install"],
      schema: [],
      only: [:dev]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    %{from: from, to: to} = igniter.args.positional

    upgrades = %{
      "0.2.0" => [&warn_removed_bang_ops/2]
    }

    igniter
    |> Igniter.compose_task("adze.install", [])
    |> Igniter.Upgrades.run(from, to, upgrades, custom_opts: igniter.args.options)
  end

  # 0.2.0 removed `mv!` / `extract!` / `rename!` / `extract-private!`: the
  # plain forms write, `--dry-run` previews. The installer has already
  # refreshed adze's own files; this flags the user's (scripts, CI, their
  # own agent notes). Reported, not rewritten: the right fix depends on
  # whether the script relied on the old dry-run default.
  @bang_op_re ~r/\badze\s+(mv|extract-private|extract|rename)!/

  @scanned_globs [
    "*.{md,exs,sh,yml,yaml,toml,json,mk}",
    "{Makefile,justfile,Justfile}",
    "{.github,.claude,.agents,.cursor,bin,script,scripts,docs}/**/*.{md,mdc,sh,yml,yaml,toml,txt}"
  ]

  # Not `Igniter.include_glob/2`: in test mode it matches globs against
  # absolute paths, so only `**/`-prefixed globs work there, and on disk
  # those would walk deps/ and _build/.
  defp candidate_paths(igniter) do
    if igniter.assigns[:test_mode?] do
      globs = Enum.map(@scanned_globs, &GlobEx.compile!(&1, match_dot: true))

      igniter.assigns[:test_files]
      |> Map.keys()
      |> Enum.filter(fn path -> Enum.any?(globs, &GlobEx.match?(&1, path)) end)
    else
      @scanned_globs |> Enum.flat_map(&Path.wildcard(&1, match_dot: true)) |> Enum.uniq()
    end
  end

  @doc false
  def warn_removed_bang_ops(igniter, _opts) do
    igniter =
      Enum.reduce(candidate_paths(igniter), igniter, &Igniter.include_existing_file(&2, &1))

    hits =
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.sort_by(& &1.path)
      |> Enum.flat_map(fn source ->
        source
        |> Rewrite.Source.get(:content)
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, n} ->
          Regex.scan(@bang_op_re, line) |> Enum.map(fn [m, _] -> "#{source.path}:#{n}  #{m}" end)
        end)
      end)

    case hits do
      [] ->
        igniter

      hits ->
        Igniter.add_warning(igniter, """
        adze 0.2.0 removed the `!` commands. `mix adze mv` (and extract,
        rename, extract-private) now writes; add --dry-run to preview.
        Update these:

        #{Enum.map_join(hits, "\n", &"  #{&1}")}
        """)
    end
  end
end
