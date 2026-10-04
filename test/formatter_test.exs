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
end
