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
    test "creates AGENTS.md from agents-snippet.md and leaves CLAUDE.md alone" do
      igniter = test_project() |> install([])

      assert_creates(igniter, "AGENTS.md")
      assert content(igniter, "AGENTS.md") =~ String.trim(@snippet)
      refute Map.has_key?(igniter.rewrite.sources, "CLAUDE.md")
    end

    test "an existing CLAUDE.md is not modified" do
      claude_md = "# Project notes\n"

      igniter =
        test_project(files: %{"CLAUDE.md" => claude_md})
        |> install([])

      assert content(igniter, "CLAUDE.md") == claude_md
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
      agents_md = "# Agents\n\n## adze — old heading text\n\nOld `mix adze` notes.\n"

      igniter = test_project(files: %{"AGENTS.md" => agents_md}) |> install([])
      agents = content(igniter, "AGENTS.md")

      assert agents == "# Agents\n\n" <> String.trim(@snippet) <> "\n"
    end

    test "leaves user-written adze notes without an adze heading alone" do
      agents_md = "# Agents\n\nWe use `mix adze ls` before reading big files.\n"

      test_project(files: %{"AGENTS.md" => agents_md})
      |> install([])
      |> assert_unchanged("AGENTS.md")
    end
  end
end
