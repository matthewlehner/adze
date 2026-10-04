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
    2. Adds an adze section to `AGENTS.md` (creating it if needed). Every
       supported agent, Claude Code included, reads `AGENTS.md`, so it's the
       only agent file adze touches; `CLAUDE.md` is left alone.

    ## Options

    * `--claude` — Install the Claude Code skill (`.claude/skills/adze/SKILL.md`)
    * `--codex` — Install the Codex/Pi/OpenCode skill (`.agents/skills/adze/SKILL.md`)

    If neither flag is passed, both skills are installed.

    ## Example

    ```sh
    #{example()}
    mix igniter.install adze --claude
    mix igniter.install adze --codex
    ```
    """
  end
end

defmodule Mix.Tasks.Adze.Install do
  @shortdoc "#{__MODULE__.Docs.short_doc()}"
  @moduledoc __MODULE__.Docs.long_doc()

  use Igniter.Mix.Task

  # Embedded at compile time: skill.md ships in the hex package next to
  # lib/, so this works wherever adze's deps live (umbrella apps, a
  # custom `deps_path`), unlike reading `deps/adze/skill.md` from the cwd.
  @skill_source_path Path.expand("../../../skill.md", __DIR__)
  @external_resource @skill_source_path
  @skill_content File.read!(@skill_source_path)

  @claude_skill_path ".claude/skills/adze/SKILL.md"
  @codex_skill_path ".agents/skills/adze/SKILL.md"
  @agents_md "AGENTS.md"

  @snippet_path Path.expand("../../../agents-snippet.md", __DIR__)
  @external_resource @snippet_path
  @skill_reference "\n" <> File.read!(@snippet_path)

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

    igniter
    |> maybe_install_claude(claude?)
    |> maybe_install_codex(codex?)
    |> patch_agents_md()
    |> add_completion_notice(claude?, codex?)
  end

  defp maybe_install_claude(igniter, false), do: igniter

  defp maybe_install_claude(igniter, true) do
    Igniter.create_new_file(igniter, @claude_skill_path, @skill_content, on_exists: :skip)
  end

  defp maybe_install_codex(igniter, false), do: igniter

  defp maybe_install_codex(igniter, true) do
    Igniter.create_new_file(igniter, @codex_skill_path, @skill_content, on_exists: :skip)
  end

  defp patch_agents_md(igniter) do
    if Igniter.exists?(igniter, @agents_md) do
      igniter
      |> Igniter.update_file(@agents_md, fn source ->
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
      Igniter.create_new_file(igniter, @agents_md, String.trim_leading(@skill_reference),
        on_exists: :skip
      )
    end
  end

  defp installed_files(claude?, codex?) do
    [
      claude? && "Skill: #{@claude_skill_path}",
      codex? && "Skill: #{@codex_skill_path}",
      "Agent instructions: #{@agents_md}"
    ]
    |> Enum.filter(& &1)
    |> Enum.map_join("\n", &"  • #{&1}")
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

    #{installed_files(claude?, codex?)}

    ## usage_rules integration (optional)

    For richer rules (error shapes, API details), also sync via usage_rules:

        mix usage_rules.sync AGENTS.md adze

    ## Quick test

        mix adze ls --file lib/your_app.ex
    """)
  end
end
