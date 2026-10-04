defmodule Adze.InstallTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  @skill File.read!(Path.expand("../skill.md", __DIR__))
  @snippet File.read!(Path.expand("../agents-snippet.md", __DIR__))

  defp install(igniter, argv), do: Igniter.compose_task(igniter, "adze.install", argv)

  defp content(igniter, path) do
    {:ok, source} = Rewrite.source(igniter.rewrite, path)
    Rewrite.Source.get(source, :content)
  end

  # The skill file must come from the adze package itself, not from a
  # `deps/adze` folder relative to the cwd (missing in umbrella apps, with a
  # custom `deps_path`, or here in adze's own repo).
  test "creates both skill files with adze's skill.md, whatever the cwd" do
    test_project()
    |> install([])
    |> assert_creates(".claude/skills/adze/SKILL.md", @skill)
    |> assert_creates(".agents/skills/adze/SKILL.md", @skill)
  end

  # Claude Code only loads skills from `.claude/skills/` and Codex/Pi/OpenCode
  # from `.agents/skills/`, so both are always installed; there are no
  # per-platform flags. Igniter ignores unknown switches, so the old
  # `--claude` / `--codex` from earlier docs still give the full install.
  test "the old per-platform flags still install both skills" do
    for flag <- ["--claude", "--codex"] do
      test_project()
      |> install([flag])
      |> assert_creates(".claude/skills/adze/SKILL.md", @skill)
      |> assert_creates(".agents/skills/adze/SKILL.md", @skill)
    end
  end

  describe "agent file" do
    test "creates AGENTS.md from agents-snippet.md and doesn't create a CLAUDE.md" do
      igniter = test_project() |> install([])

      assert_creates(igniter, "AGENTS.md")
      assert content(igniter, "AGENTS.md") =~ String.trim(@snippet)
      refute Map.has_key?(igniter.rewrite.sources, "CLAUDE.md")
    end

    test "appends the snippet to an existing AGENTS.md exactly once" do
      igniter =
        test_project(files: %{"AGENTS.md" => "# Agents\n"})
        |> install([])

      agents = content(igniter, "AGENTS.md")
      assert String.starts_with?(agents, "# Agents\n")
      assert length(String.split(agents, "## adze — structural Elixir refactoring")) == 2
    end

    test "re-running doesn't add the snippet again" do
      once = test_project() |> install([]) |> apply_igniter!()
      twice = install(once, [])

      agents = content(twice, "AGENTS.md")
      assert length(String.split(agents, "## adze — structural Elixir refactoring")) == 2
    end
  end

  # The skills and the AGENTS.md section belong to adze. Re-running the
  # installer after upgrading adze must bring them up to date, or agents keep
  # following the old version's commands and flags.
  describe "re-running after an upgrade" do
    @stale_skill "---\nname: adze\n---\n\n# adze (old version)\n"

    test "replaces stale skill files with the packaged skill.md" do
      test_project(
        files: %{
          ".claude/skills/adze/SKILL.md" => @stale_skill,
          ".agents/skills/adze/SKILL.md" => @stale_skill
        }
      )
      |> install([])
      |> then(fn igniter ->
        assert content(igniter, ".claude/skills/adze/SKILL.md") == @skill
        assert content(igniter, ".agents/skills/adze/SKILL.md") == @skill
      end)
    end

    test "leaves up-to-date skill files and AGENTS.md section untouched" do
      test_project()
      |> install([])
      |> apply_igniter!()
      |> install([])
      |> assert_unchanged([
        ".claude/skills/adze/SKILL.md",
        ".agents/skills/adze/SKILL.md",
        "AGENTS.md"
      ])
    end

    test "replaces an old adze section in AGENTS.md, keeping the rest" do
      agents_md = """
      # Agents

      Intro.

      ## adze — structural Elixir refactoring

      Old instructions with `mix adze ls --file PATH` and a removed flag.

      ## Testing

      Run mix test.
      """

      igniter = test_project(files: %{"AGENTS.md" => agents_md}) |> install([])
      agents = content(igniter, "AGENTS.md")

      assert agents =~ String.trim(@snippet)
      refute agents =~ "Old instructions"
      assert agents =~ ~r/\A# Agents\n\nIntro\.\n\n## adze/
      assert agents =~ ~r/\n\n## Testing\n\nRun mix test\.\n\z/
    end

    test "replaces an old adze section at the end of AGENTS.md" do
      agents_md = "# Agents\n\n## adze — structural Elixir refactoring\n\nOld `mix adze` notes.\n"

      igniter = test_project(files: %{"AGENTS.md" => agents_md}) |> install([])
      agents = content(igniter, "AGENTS.md")

      assert agents == "# Agents\n\n" <> String.trim(@snippet) <> "\n"
    end

    test "a user-written `## adze …` section is kept" do
      agents_md = "# Agents\n\n## adze tips\n\nRun `mix adze ls` first.\n"

      igniter = test_project(files: %{"AGENTS.md" => agents_md}) |> install([])

      assert content(igniter, "AGENTS.md") =~ "## adze tips\n\nRun `mix adze ls` first."
    end

    test "leaves user-written adze notes without an adze heading alone" do
      agents_md = "# Agents\n\nWe use `mix adze ls` before reading big files.\n"

      test_project(files: %{"AGENTS.md" => agents_md})
      |> install([])
      |> assert_unchanged("AGENTS.md")
    end
  end

  # Claude Code reads AGENTS.md only when the project has no CLAUDE.md,
  # .claude/CLAUDE.md or CLAUDE.local.md. With one present, the adze section
  # only reaches Claude through an `@AGENTS.md` import, which is what the
  # Claude Code docs recommend.
  describe "CLAUDE.md" do
    @old_section """
    ## adze — structural Elixir refactoring

    For Elixir codebase exploration: ALWAYS run `mix adze ls --file PATH`.
    """

    test "an existing CLAUDE.md gets an @AGENTS.md import, keeping its content" do
      igniter =
        test_project(files: %{"CLAUDE.md" => "# Project notes\n\nUse mix test.\n"})
        |> install([])

      assert content(igniter, "CLAUDE.md") == "# Project notes\n\nUse mix test.\n\n@AGENTS.md\n"
    end

    test "a CLAUDE.md that already imports AGENTS.md is unchanged" do
      for claude_md <- ["@AGENTS.md\n\n# Notes\n", "# Notes\n\nSee @./AGENTS.md too.\n"] do
        test_project(files: %{"CLAUDE.md" => claude_md})
        |> install([])
        |> assert_unchanged("CLAUDE.md")
      end
    end

    test "a backticked `@AGENTS.md` mention isn't an import" do
      igniter =
        test_project(files: %{"CLAUDE.md" => "# Notes\n\nWe could add `@AGENTS.md` later.\n"})
        |> install([])

      assert content(igniter, "CLAUDE.md") =~ ~r/\n\n@AGENTS\.md\n\z/
    end

    test "only .claude/CLAUDE.md: the import path is relative to that file" do
      igniter =
        test_project(files: %{".claude/CLAUDE.md" => "# Notes\n"})
        |> install([])

      assert content(igniter, ".claude/CLAUDE.md") == "# Notes\n\n@../AGENTS.md\n"
      refute Map.has_key?(igniter.rewrite.sources, "CLAUDE.md")
    end

    test "both CLAUDE.md files: only the root one gets the import" do
      igniter =
        test_project(files: %{"CLAUDE.md" => "# Root\n", ".claude/CLAUDE.md" => "# Inner\n"})
        |> install([])

      assert content(igniter, "CLAUDE.md") == "# Root\n\n@AGENTS.md\n"
      assert content(igniter, ".claude/CLAUDE.md") == "# Inner\n"
    end

    test "an import in .claude/CLAUDE.md is enough" do
      test_project(files: %{"CLAUDE.md" => "# Root\n", ".claude/CLAUDE.md" => "@../AGENTS.md\n"})
      |> install([])
      |> assert_unchanged(["CLAUDE.md", ".claude/CLAUDE.md"])
    end

    test "an old adze section (from the 0.1.0 installer) is replaced by the import" do
      claude_md = "# Project notes\n\n" <> @old_section <> "\n## Testing\n\nRun mix test.\n"

      igniter = test_project(files: %{"CLAUDE.md" => claude_md}) |> install([])

      assert content(igniter, "CLAUDE.md") ==
               "# Project notes\n\n## Testing\n\nRun mix test.\n\n@AGENTS.md\n"
    end

    test "a CLAUDE.md that only held the old adze section becomes just the import" do
      igniter = test_project(files: %{"CLAUDE.md" => @old_section}) |> install([])

      assert content(igniter, "CLAUDE.md") == "@AGENTS.md\n"
    end

    test "a user-written adze section in CLAUDE.md is kept" do
      claude_md = "# Notes\n\n## adze tips\n\nRun `mix adze ls` first.\n"

      igniter = test_project(files: %{"CLAUDE.md" => claude_md}) |> install([])

      assert content(igniter, "CLAUDE.md") == claude_md <> "\n@AGENTS.md\n"
    end

    test "re-running leaves CLAUDE.md alone" do
      test_project(files: %{"CLAUDE.md" => "# Notes\n"})
      |> install([])
      |> apply_igniter!()
      |> install([])
      |> assert_unchanged("CLAUDE.md")
    end

    test "CLAUDE.local.md is never edited, but the notice says what to do" do
      igniter =
        test_project(files: %{"CLAUDE.local.md" => "# Mine\n"})
        |> install([])
        |> assert_unchanged("CLAUDE.local.md")

      assert Enum.any?(igniter.notices, &(&1 =~ "CLAUDE.local.md" and &1 =~ "@AGENTS.md"))
    end

    test "the notice mentions an updated CLAUDE.md" do
      igniter = test_project(files: %{"CLAUDE.md" => "# Notes\n"}) |> install([])
      assert Enum.any?(igniter.notices, &(&1 =~ "CLAUDE.md" and &1 =~ "@AGENTS.md"))
    end
  end
end
