defmodule Mix.Tasks.Adze.Install.Docs do
  @moduledoc false

  def short_doc, do: "Installs adze into your project"
  def example, do: "mix igniter.install adze"

  def long_doc do
    """
    #{short_doc()}

    Sets up adze as a dev tool and integrates it with your LLM-based
    workflow (Claude Code, Codex, OpenCode, Pi, etc.).

    ## What it does

    1. Creates a skill file in the appropriate location for your agent platform
    2. Patches your `CLAUDE.md` or `AGENTS.md` to reference the skill

    ## Options

    * `--claude` — Install for Claude Code (`.claude/skills/adze/SKILL.md` + `CLAUDE.md`)
    * `--codex` — Install for Codex/Pi/OpenCode (`.agents/skills/adze/SKILL.md` + `AGENTS.md`)

    If neither flag is passed, both are installed.

    ## Example

    ```sh
    #{example()}
    mix igniter.install adze --claude
    mix igniter.install adze --codex
    ```
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Adze.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @claude_skill_path ".claude/skills/adze/SKILL.md"
    @codex_skill_path ".agents/skills/adze/SKILL.md"
    @claude_md "CLAUDE.md"
    @agents_md "AGENTS.md"

    @skill_reference """

    ## adze — structural Elixir refactoring

    For Elixir codebase exploration: ALWAYS run `mix adze ls --file PATH` before
    reading `.ex` files or spawning exploration agents. Measured: ~150x more
    token-efficient than reading full files (maps a 2000-line module in ~50 tokens
    with exact line ranges, vs reading the whole file). Returns in milliseconds.
    Use the outline to identify the line range you need, then Read only that range.

    For structural edits (rename, extract, move, privatize): ALWAYS use `mix adze`
    instead of multi-edit. The tool does AST-aware rewrites across the entire project
    in one pass — no missed call sites, no broken aliases, no formatting drift.

    Key commands:
    - `mix adze ls --file PATH` — structural outline with line ranges (~50 tokens per file)
    - `mix adze find-callers --target Mod.fun/N` — project-wide caller search (resolves aliases, pipes, captures)
    - `mix adze rename! --from Old --to New` — rename a module across the entire project
    - `mix adze extract! --file PATH --definition fun/N --module New.Mod` — extract function + private closure into new module
    - `mix adze mv! --file PATH --definition fun/N --before other/M` — reorder defs within a module
    - `mix adze extract-private! --file PATH --definition fun/N` — flip def → defp after verifying no external callers

    Always dry-run first (no `!`), then apply with `!`. Run `mix compile --warnings-as-errors` after writes.

    Full reference (flags, caveats, workflows): see the adze skill file in this project's skills directory.
    """

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :adze,
        example: __MODULE__.Docs.example(),
        schema: [
          claude: :boolean,
          codex: :boolean
        ],
        only: [:dev]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      claude? = igniter.args.options[:claude]
      codex? = igniter.args.options[:codex]

      # Default: install both if neither flag is passed
      {claude?, codex?} =
        if !claude? && !codex? do
          {true, true}
        else
          {claude? || false, codex? || false}
        end

      skill_content = read_skill_source()

      igniter
      |> maybe_install_claude(claude?, skill_content)
      |> maybe_install_codex(codex?, skill_content)
      |> add_completion_notice(claude?, codex?)
    end

    defp read_skill_source do
      path = Path.join(["deps", "adze", "skill.md"])

      if File.exists?(path) do
        File.read!(path)
      else
        nil
      end
    end

    defp maybe_install_claude(igniter, false, _content), do: igniter

    defp maybe_install_claude(igniter, true, nil) do
      Igniter.add_warning(igniter, """
      Could not find deps/adze/skill.md — skipping Claude Code skill creation.
      """)
    end

    defp maybe_install_claude(igniter, true, content) do
      igniter
      |> Igniter.create_new_file(@claude_skill_path, content, on_exists: :skip)
      |> patch_agent_file(@claude_md)
    end

    defp maybe_install_codex(igniter, false, _content), do: igniter

    defp maybe_install_codex(igniter, true, nil) do
      Igniter.add_warning(igniter, """
      Could not find deps/adze/skill.md — skipping Codex skill creation.
      """)
    end

    defp maybe_install_codex(igniter, true, content) do
      igniter
      |> Igniter.create_new_file(@codex_skill_path, content, on_exists: :skip)
      |> patch_agent_file(@agents_md)
    end

    defp patch_agent_file(igniter, path) do
      if Igniter.exists?(igniter, path) do
        igniter
        |> Igniter.update_file(path, fn source ->
          current = Rewrite.Source.get(source, :content)

          if String.contains?(current, "mix adze") do
            # Already has adze references, don't double-add
            source
          else
            Rewrite.Source.update(source, :content, current <> @skill_reference)
          end
        end)
      else
        # Create the file with just the adze section
        Igniter.create_new_file(igniter, path, String.trim_leading(@skill_reference),
          on_exists: :skip
        )
      end
    end

    defp add_completion_notice(igniter, claude?, codex?) do
      platforms =
        []
        |> then(fn acc -> if claude?, do: ["Claude Code" | acc], else: acc end)
        |> then(fn acc -> if codex?, do: ["Codex/Pi/OpenCode" | acc], else: acc end)
        |> Enum.reverse()
        |> Enum.join(", ")

      Igniter.add_notice(igniter, """
      Adze installed for: #{platforms}

      #{if claude?, do: "  • Skill: #{@claude_skill_path}", else: ""}
      #{if codex?, do: "  • Skill: #{@codex_skill_path}", else: ""}

      ## usage_rules integration (optional)

      For richer rules (error shapes, API details), also sync via usage_rules:

          mix usage_rules.sync AGENTS.md adze

      ## Quick test

          mix adze ls --file lib/your_app.ex
      """)
    end
  end
else
  defmodule Mix.Tasks.Adze.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'adze.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
