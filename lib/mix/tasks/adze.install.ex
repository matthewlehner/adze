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

    1. Installs the adze skill where each agent looks for it:
       `.claude/skills/adze/SKILL.md` (Claude Code) and
       `.agents/skills/adze/SKILL.md` (Codex, Pi, OpenCode).
    2. Adds an adze section to `AGENTS.md`, creating it if needed.

    ## Example

    ```sh
    #{example()}
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

  # Claude Code only loads skills from `.claude/skills/`; Codex, Pi and
  # OpenCode from `.agents/skills/`. Both are always installed.
  @skill_paths [".claude/skills/adze/SKILL.md", ".agents/skills/adze/SKILL.md"]
  @agents_md "AGENTS.md"

  @snippet_path Path.expand("../../../agents-snippet.md", __DIR__)
  @external_resource @snippet_path
  @agents_section @snippet_path |> File.read!() |> String.trim()

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :adze,
      example: __MODULE__.Docs.example(),
      schema: [],
      only: [:dev]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    @skill_paths
    |> Enum.reduce(igniter, &install_skill(&2, &1))
    |> patch_agents_md()
    |> add_completion_notice()
  end

  # The skill files belong to adze: overwrite them so re-running the
  # installer after an upgrade brings them up to date.
  defp install_skill(igniter, path) do
    Igniter.create_or_update_file(igniter, path, @skill_content, fn source ->
      Rewrite.Source.update(source, :content, @skill_content)
    end)
  end

  defp patch_agents_md(igniter) do
    Igniter.create_or_update_file(igniter, @agents_md, @agents_section <> "\n", fn source ->
      current = Rewrite.Source.get(source, :content)

      case put_adze_section(current, @agents_section) do
        ^current -> source
        updated -> Rewrite.Source.update(source, :content, updated)
      end
    end)
  end

  # The adze section starts at its `## adze` heading and runs to the next
  # `#` / `##` heading or the end of the file. Replace it when present (so
  # upgrades refresh it); append it when the file has no adze mention at
  # all; leave user-written adze notes without that heading alone.
  @section_re ~r/^## adze\b.*?(?=^\#{1,2} |\z)/ms

  defp put_adze_section(content, section) do
    case Regex.run(@section_re, content, return: :index) do
      [{start, len}] ->
        before = binary_part(content, 0, start)
        rest = binary_part(content, start + len, byte_size(content) - start - len)
        before <> section <> if(rest == "", do: "\n", else: "\n\n") <> rest

      nil ->
        if String.contains?(content, "mix adze"),
          do: content,
          else: String.trim_trailing(content) <> "\n\n" <> section <> "\n"
    end
  end

  defp add_completion_notice(igniter) do
    files =
      Enum.map(@skill_paths, &"Skill: #{&1}") ++ ["Agent instructions: #{@agents_md}"]

    Igniter.add_notice(igniter, """
    Adze installed.

    #{Enum.map_join(files, "\n", &"  • #{&1}")}

    ## usage_rules integration (optional)

    For richer rules (error shapes, API details), also sync via usage_rules:

        mix usage_rules.sync AGENTS.md adze

    ## Quick test

        mix adze ls --file lib/your_app.ex
    """)
  end
end
