defmodule AdzeMoveTest do
  use ExUnit.Case, async: true

  alias Adze.Move

  describe "mv/2 — basic moves" do
    test "moves a simple def before another in the same module" do
      source = """
      defmodule X do
        def foo(x), do: x + 1

        def bar(x), do: x - 1
      end
      """

      {:ok, result} = Move.mv(source, definition: "bar/1", before: "foo/1")
      assert def_order(result.new_source, "X") == [{:bar, 1}, {:foo, 1}]
      assert result.diff =~ "@@"
      assert result.diff =~ "+"
      assert result.diff =~ "-"
    end

    test "@spec and @doc move with the def" do
      source = """
      defmodule X do
        @doc "first"
        @spec foo() :: :ok
        def foo, do: :ok

        @doc "second"
        @spec bar() :: :ok
        def bar, do: :ok
      end
      """

      {:ok, result} = Move.mv(source, definition: "bar/0", before: "foo/0")
      assert result.new_source =~ ~r/@doc "second".*@spec bar.*def bar.*@doc "first".*@spec foo.*def foo/s
    end

    test "leading comment block moves with the def" do
      source = """
      defmodule X do
        # comment above bar
        def bar, do: :bar

        def foo, do: :foo
      end
      """

      {:ok, result} = Move.mv(source, definition: "bar/0", before: "foo/0")
      # bar's comment must appear immediately above bar in the new source,
      # and foo must not pick up the comment.
      assert result.new_source =~ ~r/# comment above bar\s*\n\s*def bar/
      refute result.new_source =~ ~r/# comment above bar\s*\n\s*def foo/
    end

    test "all clauses of a multi-clause def move as one group" do
      source = """
      defmodule X do
        def greet(name) when is_binary(name), do: "hi " <> name
        def greet(_), do: "hello stranger"

        def other, do: :ok
      end
      """

      {:ok, result} = Move.mv(source, definition: "other/0", before: "greet/1")
      # other should come first; greet/1 (collapsed multi-clause group) follows.
      assert def_order(result.new_source, "X") == [{:other, 0}, {:greet, 1}]
      # Both clauses must still be present in the source.
      assert result.new_source =~ ~r/def greet\(name\) when is_binary\(name\)/
      assert result.new_source =~ ~r/def greet\(_\)/
    end

    test "forward move (source before target) reorders correctly" do
      source = """
      defmodule X do
        def a, do: :a
        def b, do: :b
        def c, do: :c
      end
      """

      {:ok, result} = Move.mv(source, definition: "a/0", before: "c/0")
      assert def_order(result.new_source, "X") == [{:b, 0}, {:a, 0}, {:c, 0}]
    end

    test "backward move (source after target) reorders correctly" do
      source = """
      defmodule X do
        def a, do: :a
        def b, do: :b
        def c, do: :c
      end
      """

      {:ok, result} = Move.mv(source, definition: "c/0", before: "a/0")
      assert def_order(result.new_source, "X") == [{:c, 0}, {:a, 0}, {:b, 0}]
    end

    test "result is well-formed and re-parses to the expected definitions" do
      source = """
      defmodule X do
        def a, do: :a
        def b, do: :b
      end
      """

      {:ok, result} = Move.mv(source, definition: "b/0", before: "a/0")
      {:ok, defs} = Adze.Definition.list(result.new_source)

      assert Enum.map(defs, &{&1.name, &1.arity, &1.module}) == [
               {:b, 0, "X"},
               {:a, 0, "X"}
             ]
    end
  end

  describe "mv/2 — error cases" do
    test "self anchor: --definition and --before are the same" do
      source = "defmodule X do\n  def a, do: :a\nend\n"
      assert Move.mv(source, definition: "a/0", before: "a/0") == {:error, :self_anchor}
    end

    test "source definition not found is labeled :definition" do
      source = "defmodule X do\n  def a, do: :a\nend\n"

      assert Move.mv(source, definition: "nope/0", before: "a/0") ==
               {:error, {:not_found, :definition}}
    end

    test "before target not found is labeled :before" do
      source = "defmodule X do\n  def a, do: :a\nend\n"
      assert Move.mv(source, definition: "a/0", before: "nope/0") == {:error, {:not_found, :before}}
    end

    test "cross-module move is rejected" do
      source = """
      defmodule A do
        def alpha, do: :a
      end

      defmodule B do
        def beta, do: :b
      end
      """

      assert {:error, {:cross_module_move, info}} =
               Move.mv(source, definition: "alpha/0", before: "beta/0")

      assert info.definition_module == "A"
      assert info.before_module == "B"
    end

    test "missing :definition opt" do
      source = "defmodule X do\nend\n"
      assert {:error, {:missing_opt, :definition}} = Move.mv(source, before: "foo/0")
    end

    test "missing :before opt" do
      source = "defmodule X do\nend\n"
      assert {:error, {:missing_opt, :before}} = Move.mv(source, definition: "foo/0")
    end
  end

  describe "mv/2 — diff output" do
    test "no-op move (source already immediately before target) produces empty diff" do
      source = """
      defmodule X do
        def a, do: :a

        def b, do: :b
      end
      """

      {:ok, result} = Move.mv(source, definition: "a/0", before: "b/0")
      assert result.diff == ""
      assert result.new_source == source
    end

    test "diff includes unified header and hunk markers" do
      source = """
      defmodule X do
        def a, do: :a

        def b, do: :b

        def c, do: :c
      end
      """

      {:ok, result} = Move.mv(source, definition: "c/0", before: "a/0")
      assert String.starts_with?(result.diff, "--- a\n+++ b\n")
      assert result.diff =~ ~r/@@ -\d+,\d+ \+\d+,\d+ @@/
    end
  end

  describe "mv/2 — boundary cases" do
    test "first def in module → before last def (no leading blank above source)" do
      source = """
      defmodule X do
        def first, do: 1
        def middle, do: 2
        def last, do: 3
      end
      """

      {:ok, result} = Move.mv(source, definition: "first/0", before: "last/0")
      assert def_order(result.new_source, "X") == [{:middle, 0}, {:first, 0}, {:last, 0}]
      assert {:ok, _} = Code.string_to_quoted(result.new_source)
    end

    test "last def in module → before first def (no trailing blank under source)" do
      source = """
      defmodule X do
        def first, do: 1
        def middle, do: 2
        def last, do: 3
      end
      """

      {:ok, result} = Move.mv(source, definition: "last/0", before: "first/0")
      assert def_order(result.new_source, "X") == [{:last, 0}, {:first, 0}, {:middle, 0}]
      assert {:ok, _} = Code.string_to_quoted(result.new_source)
    end

    test "comment block immediately after moved def, no blank between, stays put" do
      # The trailing comment block belongs to `bar` (Sourceror attaches
      # leading comments to the *next* AST node). Moving `foo` must
      # not pull bar's comments out from under bar.
      source = """
      defmodule X do
        def foo, do: :foo
        # this comment belongs to bar
        # second line
        def bar, do: :bar
        def baz, do: :baz
      end
      """

      {:ok, result} = Move.mv(source, definition: "foo/0", before: "baz/0")
      # bar's comments must still be immediately above bar
      assert result.new_source =~ ~r/# this comment belongs to bar\s*\n\s*# second line\s*\n\s*def bar/
      # and must not have followed foo to its new spot
      refute result.new_source =~ ~r/# this comment belongs to bar\s*\n\s*# second line\s*\n\s*def foo/
    end

    test "sigil heredoc in body containing text resembling def doesn't fool slicing" do
      # The line-based slice relies on Definition.range, which comes
      # from Sourceror's AST-derived ranges — so heredoc lines that
      # *look* like top-level definitions can't confuse it. This test pins
      # that down.
      source = """
      defmodule X do
        def code_sample do
          ~S\"\"\"
          defmodule Fake do
            def looks_like_a_def, do: :nope
          end
          \"\"\"
        end

        def other, do: :ok
      end
      """

      {:ok, result} = Move.mv(source, definition: "other/0", before: "code_sample/0")
      assert def_order(result.new_source, "X") == [{:other, 0}, {:code_sample, 0}]
      # the heredoc payload must be intact and still attached to code_sample
      assert result.new_source =~ ~r/def code_sample do.*defmodule Fake.*looks_like_a_def/s
      # and the fake def must not have leaked into the outer module
      {:ok, defs} = Adze.Definition.list(result.new_source)
      refute Enum.any?(defs, &(&1.name == :looks_like_a_def))
    end
  end

  describe "mv_file/2 + mv!/2" do
    @tmpdir System.tmp_dir!()

    setup do
      path = Path.join(@tmpdir, "adze_mv_test_#{System.unique_integer([:positive])}.ex")
      File.write!(path, """
      defmodule TmpMod do
        def a, do: :a
        def b, do: :b
      end
      """)

      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "mv_file returns the result without writing", %{path: path} do
      original = File.read!(path)
      {:ok, result} = Move.mv_file(path, definition: "b/0", before: "a/0")
      assert result.diff != ""
      assert File.read!(path) == original
    end

    test "mv! writes the new source to disk", %{path: path} do
      {:ok, result} = Move.mv!(path, definition: "b/0", before: "a/0")
      assert File.read!(path) == result.new_source
      assert def_order(File.read!(path), "TmpMod") == [{:b, 0}, {:a, 0}]
    end

    test "mv! returns {:error, {:file_write, _}} for unwritable target", %{path: path} do
      File.chmod!(path, 0o444)
      on_exit(fn -> File.chmod(path, 0o644) end)

      assert {:error, {:file_write, _reason}} = Move.mv!(path, definition: "b/0", before: "a/0")
    end
  end

  # --- helpers -----------------------------------------------------------

  # Extract {name, arity} of every def-family group in a module from the
  # given source, in source order. Used to assert reordering happened
  # correctly without dragging in raw diff string matching.
  defp def_order(source, module_name) do
    {:ok, defs} = Adze.Definition.list(source)

    defs
    |> Enum.filter(&(&1.module == module_name))
    |> Enum.map(&{&1.name, &1.arity})
  end
end
