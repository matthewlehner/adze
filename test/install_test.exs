defmodule Adze.InstallTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  @skill File.read!(Path.expand("../skill.md", __DIR__))

  # The skill file must come from the adze package itself, not from a
  # `deps/adze` folder relative to the cwd (missing in umbrella apps, with a
  # custom `deps_path`, or here in adze's own repo).
  test "creates both skill files with adze's skill.md, whatever the cwd" do
    test_project()
    |> Igniter.compose_task("adze.install", [])
    |> assert_creates(".claude/skills/adze/SKILL.md", @skill)
    |> assert_creates(".agents/skills/adze/SKILL.md", @skill)
  end

  test "--claude installs only the Claude Code skill" do
    igniter =
      test_project()
      |> Igniter.compose_task("adze.install", ["--claude"])
      |> assert_creates(".claude/skills/adze/SKILL.md", @skill)

    refute Map.has_key?(igniter.rewrite.sources, ".agents/skills/adze/SKILL.md")
  end
end
