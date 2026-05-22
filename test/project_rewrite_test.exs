defmodule AdzeProjectRewriteTest do
  use ExUnit.Case, async: true

  alias Adze.ProjectRewrite

  describe "new/1" do
    test "in-memory test mode keeps the rewrite isolated" do
      {:ok, rewrite} = ProjectRewrite.new(files: %{"lib/foo.ex" => "defmodule Foo do\nend\n"})
      assert rewrite.test? == true
      assert rewrite.igniter.assigns[:test_mode?] == true
    end

    test "returns a struct that wraps the Igniter" do
      {:ok, rewrite} = ProjectRewrite.new(files: %{})
      assert %ProjectRewrite{igniter: %Igniter{}} = rewrite
    end
  end

  describe "rename_module/3 + result/1" do
    test "rewrite is empty when there's nothing to rename" do
      {:ok, rewrite} =
        ProjectRewrite.new(files: %{"lib/a.ex" => "defmodule A do\nend\n"})

      # Renaming a module that doesn't exist in the project still
      # succeeds — Igniter just has nothing to do.
      {:ok, rewrite, _report} = ProjectRewrite.rename_module(rewrite, Nonexistent.Old, Nonexistent.New)
      {:ok, result} = ProjectRewrite.result(rewrite)

      assert result.diffs == %{}
      assert result.moves == %{}
    end

    test "diffs are keyed by source path" do
      {:ok, rewrite} =
        ProjectRewrite.new(
          files: %{
            "lib/old.ex" => """
            defmodule MyApp.Old do
              def hello, do: :world
            end
            """,
            "lib/caller.ex" => """
            defmodule MyApp.Caller do
              def go, do: MyApp.Old.hello()
            end
            """
          }
        )

      {:ok, rewrite, _report} = ProjectRewrite.rename_module(rewrite, MyApp.Old, MyApp.New)
      {:ok, result} = ProjectRewrite.result(rewrite)

      assert Map.has_key?(result.diffs, "lib/caller.ex")
      # Source diffs are non-empty for changed files.
      assert is_binary(result.diffs["lib/caller.ex"])
      assert result.diffs["lib/caller.ex"] != ""
    end
  end

  describe "write!/1" do
    test "raises on a test-mode rewrite" do
      {:ok, rewrite} = ProjectRewrite.new(files: %{})

      assert_raise ArgumentError, ~r/test-mode/, fn ->
        ProjectRewrite.write!(rewrite)
      end
    end
  end
end
