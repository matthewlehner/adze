defmodule Adze.UpgradeTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  @skill File.read!(Path.expand("../skill.md", __DIR__))

  defp upgrade(igniter, from, to),
    do: Igniter.compose_task(igniter, "adze.upgrade", [from, to])

  defp content(igniter, path) do
    {:ok, source} = Rewrite.source(igniter.rewrite, path)
    Rewrite.Source.get(source, :content)
  end

  defp warnings_text(igniter), do: Enum.join(igniter.warnings, "\n")

  @old_section """
  ## adze — structural Elixir refactoring

  Run the dry-run form first, then `mix adze mv!`.
  """

  test "refreshes stale skill files and the AGENTS.md section" do
    igniter =
      test_project(
        files: %{
          ".claude/skills/adze/SKILL.md" => "old skill: mix adze mv!\n",
          ".agents/skills/adze/SKILL.md" => "old skill: mix adze mv!\n",
          "AGENTS.md" => "# Agents\n\n" <> @old_section
        }
      )
      |> upgrade("0.1.0", "0.2.0")

    assert content(igniter, ".claude/skills/adze/SKILL.md") == @skill
    assert content(igniter, ".agents/skills/adze/SKILL.md") == @skill
    refute content(igniter, "AGENTS.md") =~ "mv!"
    assert content(igniter, "AGENTS.md") =~ "# Agents\n"
  end

  test "adze's own refreshed files don't trigger the removed-command warning" do
    igniter =
      test_project(
        files: %{
          ".claude/skills/adze/SKILL.md" => "mix adze mv!\n",
          "AGENTS.md" => @old_section
        }
      )
      |> upgrade("0.1.0", "0.2.0")

    refute warnings_text(igniter) =~ "removed the `!` commands"
  end

  test "warns about each leftover ! command in the user's files, with locations" do
    igniter =
      test_project(
        files: %{
          "Makefile" => "refactor:\n\tmix adze rename! --from A --to B\n",
          ".github/workflows/ci.yml" => "run: |\n  mix adze extract-private! --file x\n",
          "AGENTS.md" => "# Agents\n\nMy note: use `mix adze extract! ...` for splits.\n"
        }
      )
      |> upgrade("0.1.0", "0.2.0")

    warning = warnings_text(igniter)
    assert warning =~ "removed the `!` commands"
    assert warning =~ "Makefile:2  adze rename!"
    assert warning =~ ".github/workflows/ci.yml:2  adze extract-private!"
    assert warning =~ "AGENTS.md:3  adze extract!"

    # Reported, never rewritten.
    assert content(igniter, "Makefile") =~ "mix adze rename! --from A --to B"
  end

  test "doesn't flag non-bang commands or other tools' ! commands" do
    igniter =
      test_project(files: %{"Makefile" => "a:\n\tmix adze mv --file x\n\tmix ecto.reset!\n"})
      |> upgrade("0.1.0", "0.2.0")

    refute warnings_text(igniter) =~ "removed the `!` commands"
  end

  test "upgrades past 0.2.0 still refresh the skill but skip the 0.2.0 check" do
    igniter =
      test_project(
        files: %{
          ".claude/skills/adze/SKILL.md" => "stale\n",
          "Makefile" => "a:\n\tmix adze mv! --file x\n"
        }
      )
      |> upgrade("0.2.0", "0.2.1")

    assert content(igniter, ".claude/skills/adze/SKILL.md") == @skill
    refute warnings_text(igniter) =~ "removed the `!` commands"
  end
end
