defmodule Adze.FormatterTest do
  use ExUnit.Case, async: true

  alias Adze.Formatter

  describe "format_extract/2 text output" do
    test "renders every section in order" do
      result = %{
        target_path: "lib/my_app/helper.ex",
        target_module: "MyApp.Helper",
        target_content: "defmodule MyApp.Helper do\nend\n",
        source_module: "MyApp.Source",
        source_diff: "-old\n+new\n",
        caller_diffs: %{"lib/b.ex" => "b-diff\n", "lib/a.ex" => "a-diff\n"},
        promoted: [{:helper, 1}],
        promoted_in_source: [{:shared, 2}],
        dropped_directives: [
          %{kind: :use, line: 4, text: "use GenServer"},
          %{kind: :import, line: 2, text: "import Bitwise"}
        ]
      }

      assert Formatter.format_extract(result, :text) == """
             # new file: lib/my_app/helper.ex (MyApp.Helper)
             defmodule MyApp.Helper do
             end

             # source diff
             -old
             +new

             # caller diffs

             # caller: lib/a.ex
             a-diff

             # caller: lib/b.ex
             b-diff

             # promoted to public in MyApp.Helper (was private; marked @doc false)
               helper/1

             # promoted to public in MyApp.Source (private helper still used by the source, now called from MyApp.Helper; marked @doc false)
               shared/2

             # dropped directives (use / import / require)
             # add back to the new target module if the build needs them.
               source:2  import Bitwise
               source:4  use GenServer
             """
    end

    test "omits empty sections and marks an unchanged source" do
      result = %{
        target_path: "lib/x.ex",
        target_module: "X",
        target_content: "defmodule X do\nend\n",
        source_module: "S",
        source_diff: ""
      }

      assert Formatter.format_extract(result, :text) ==
               "# new file: lib/x.ex (X)\ndefmodule X do\nend\n\n# source diff\n(no changes)\n"
    end
  end

  describe "diff_counts/1" do
    test "counts a unified diff, ignoring the ---/+++ headers" do
      diff = "--- a\n+++ b\n@@ -1,3 +1,3 @@\n a\n-b\n-c\n+B\n d\n"
      assert Formatter.diff_counts(diff) == {1, 2}
    end

    test "counts Rewrite's numbered rename diff" do
      diff = "  1     - |defmodule A do\n      1 + |defmodule B do\n  2   2   |  def x, do: 1\n"
      assert Formatter.diff_counts(diff) == {1, 1}
    end
  end

  describe ":summary output" do
    test "extract lists files and +/- counts, keeps what needs acting on" do
      result = %{
        path: "lib/my_app/source.ex",
        target_path: "lib/my_app/helper.ex",
        target_module: "MyApp.Helper",
        target_content: "defmodule MyApp.Helper do\n  def a, do: 1\n\n  def b, do: 2\nend\n",
        source_module: "MyApp.Source",
        source_diff: "--- a\n+++ b\n@@ -1,2 +1,1 @@\n-x\n-y\n z\n",
        caller_diffs: %{"lib/b.ex" => "--- a\n+++ b\n-old\n+new\n"},
        dropped_directives: [%{kind: :use, line: 4, text: "use GenServer"}]
      }

      assert Formatter.format_extract(result, :summary) == """
             # extract → MyApp.Helper
               created  lib/my_app/helper.ex  (5 lines)
               updated  lib/my_app/source.ex  (+0 −2)
               updated  lib/b.ex  (+1 −1)

             # dropped directives (use / import / require)
             # add back to the new target module if the build needs them.
               source:4  use GenServer
             """
    end

    test "rename lists moves, files and warnings" do
      result = %{
        from: A.Old,
        to: A.New,
        moves: %{"lib/a/old.ex" => "lib/a/new.ex"},
        diffs: %{
          "lib/a/old.ex" => "  1     - |defmodule A.Old do\n      1 + |defmodule A.New do\n"
        },
        warnings: ["something odd"],
        notices: []
      }

      assert Formatter.format_rename(result, :summary) == """
             # rename A.Old → A.New

             # moves
               lib/a/old.ex → lib/a/new.ex

             # files
               updated  lib/a/old.ex  (+1 −1)

             # warnings
               - something odd
             """
    end
  end
end
