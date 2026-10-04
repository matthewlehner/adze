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
    3. If the project has a `CLAUDE.md` (or `.claude/CLAUDE.md`), appends an
       `@AGENTS.md` import to it: Claude Code ignores `AGENTS.md` when a
       `CLAUDE.md` exists. Also removes the adze section older versions
       wrote there. `CLAUDE.local.md` is never edited.

    Re-run it after upgrading adze to refresh the skills and the
    `AGENTS.md` section.

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

  # Claude Code reads AGENTS.md only when the project has none of these. With
  # one present, AGENTS.md reaches Claude only through an `@` import, whose
  # path is relative to the file containing it.
  @claude_mds [{"CLAUDE.md", "@AGENTS.md"}, {".claude/CLAUDE.md", "@../AGENTS.md"}]
  @claude_local_md "CLAUDE.local.md"

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
    |> patch_claude_md()
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

  # The adze section starts at a heading the installer wrote and runs to the
  # next `#` / `##` heading or the end of the file. Only those exact headings
  # count, so a section you wrote yourself (`## adze tips`) is never
  # replaced or removed. Keep every heading any release has written here.
  @installer_headings ["## adze — structural Elixir refactoring"]

  @agents_heading @agents_section |> String.split("\n", parts: 2) |> hd()

  unless @agents_heading in @installer_headings do
    raise "agents-snippet.md must start with one of @installer_headings"
  end

  @section_re Regex.compile!(
                "^(?:" <>
                  Enum.map_join(@installer_headings, "|", &Regex.escape/1) <>
                  ")[ \\t]*$.*?(?=^\#{1,2} |\\z)",
                "ms"
              )

  # Replace the section when present (so upgrades refresh it); append it
  # when the file has no adze mention at all; leave user-written adze
  # notes alone.

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

  # Point an existing CLAUDE.md at AGENTS.md, and drop the adze section the
  # 0.1.0 installer wrote into it (AGENTS.md now carries it). Never creates a
  # CLAUDE.md, never edits CLAUDE.local.md (personal, usually gitignored),
  # and skips symlinks (writing through one would edit its target).
  defp patch_claude_md(igniter) do
    present =
      Enum.filter(@claude_mds, fn {path, _} ->
        Igniter.exists?(igniter, path) and not symlink?(path)
      end)

    igniter = Enum.reduce(present, igniter, fn {path, _}, ig -> drop_adze_section(ig, path) end)

    imported? = Enum.any?(present, fn {path, _} -> imports_agents_md?(igniter, path) end)

    case {imported?, present} do
      {false, [{path, import} | _]} ->
        igniter |> add_import(path, import) |> add_completion_notice({:imported, path, import})

      {false, []} ->
        if Igniter.exists?(igniter, @claude_local_md) and
             not imports_agents_md?(igniter, @claude_local_md),
           do: add_completion_notice(igniter, :local_only),
           else: add_completion_notice(igniter, nil)

      {true, _} ->
        add_completion_notice(igniter, nil)
    end
  end

  defp drop_adze_section(igniter, path) do
    Igniter.update_file(igniter, path, fn source ->
      current = Rewrite.Source.get(source, :content)

      case Regex.replace(@section_re, current, "", global: false) do
        ^current -> source
        updated -> Rewrite.Source.update(source, :content, tidy(updated))
      end
    end)
  end

  defp add_import(igniter, path, import) do
    Igniter.update_file(igniter, path, fn source ->
      content = tidy(Rewrite.Source.get(source, :content))
      updated = if content == "", do: import <> "\n", else: content <> "\n" <> import <> "\n"
      Rewrite.Source.update(source, :content, updated)
    end)
  end

  # Trailing whitespace collapsed to one newline; empty stays empty.
  defp tidy(content) do
    case String.trim_trailing(content) do
      "" -> ""
      trimmed -> trimmed <> "\n"
    end
  end

  # `@AGENTS.md`, `@./AGENTS.md`, `@../AGENTS.md`, … outside a code span
  # (Claude doesn't expand imports in backticks).
  @import_re ~r/(?<![`\w])@(?:\.{1,2}\/)*AGENTS\.md\b/

  defp imports_agents_md?(igniter, path) do
    igniter = Igniter.include_existing_file(igniter, path)

    case Rewrite.source(igniter.rewrite, path) do
      {:ok, source} -> Regex.match?(@import_re, Rewrite.Source.get(source, :content))
      _ -> false
    end
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  defp add_completion_notice(igniter, claude_md) do
    files =
      Enum.map(@skill_paths, &"Skill: #{&1}") ++
        ["Agent instructions: #{@agents_md}"] ++
        claude_md_line(claude_md)

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

  defp claude_md_line({:imported, path, import}),
    do: ["Claude Code: added `#{import}` to #{path} so Claude reads #{@agents_md}"]

  defp claude_md_line(:local_only),
    do: [
      "Claude Code: #{@claude_local_md} stops Claude reading #{@agents_md} on its own. " <>
        "Add an `@AGENTS.md` line to it (adze doesn't edit personal files)."
    ]

  defp claude_md_line(nil), do: []
end
