defmodule Adze.ExtractPrivateTest do
  use ExUnit.Case, async: false

  alias Adze.ExtractPrivate

  describe "extract_private/2 — basic flip" do
    test "flips def to defp when only internal callers exist" do
      source = """
      defmodule MyApp.Foo do
        def public_api(x), do: helper(x) + 1
        def helper(x), do: x * 2
      end
      """

      {:ok, result} =
        ExtractPrivate.extract_private(source,
          definition: "helper/1",
          path: "lib/foo.ex",
          files: %{"lib/foo.ex" => source}
        )

      assert result.from_kind == :def
      assert result.to_kind == :defp
      assert result.module == "MyApp.Foo"
      assert result.name == :helper
      assert result.arity == 1
      assert result.new_source =~ "defp helper(x)"
      refute result.new_source =~ ~r/^\s*def helper\(x\)/m
    end

    test "flips defmacro to defmacrop" do
      source = """
      defmodule X do
        def go(x), do: dbg(x)
        defmacro dbg(expr) do
          quote do
            IO.inspect(unquote(expr))
          end
        end
      end
      """

      {:ok, result} =
        ExtractPrivate.extract_private(source,
          definition: "dbg/1",
          path: "lib/x.ex",
          files: %{"lib/x.ex" => source}
        )

      assert result.from_kind == :defmacro
      assert result.to_kind == :defmacrop
      assert result.new_source =~ "defmacrop dbg(expr)"
    end

    test "flips defguard to defguardp" do
      source = """
      defmodule X do
        defguard is_pos(n) when is_integer(n) and n > 0
        def positive?(n) when is_pos(n), do: true
        def positive?(_), do: false
      end
      """

      {:ok, result} =
        ExtractPrivate.extract_private(source,
          definition: "is_pos/1",
          path: "lib/x.ex",
          files: %{"lib/x.ex" => source}
        )

      assert result.to_kind == :defguardp
      assert result.new_source =~ "defguardp is_pos(n)"
    end

    test "multi-clause def: every clause line flips" do
      source = """
      defmodule X do
        def caller, do: helper(1)
        def helper(0), do: :zero
        def helper(n) when n > 0, do: :positive
        def helper(_), do: :other
      end
      """

      {:ok, result} =
        ExtractPrivate.extract_private(source,
          definition: "helper/1",
          path: "lib/x.ex",
          files: %{"lib/x.ex" => source}
        )

      # All three clauses flip.
      refute result.new_source =~ ~r/^\s*def helper/m
      assert result.new_source =~ "defp helper(0)"
      assert result.new_source =~ "defp helper(n) when n > 0"
      assert result.new_source =~ "defp helper(_)"
    end

    test "preserves attached @doc / @spec — they're already valid on defp" do
      source = """
      defmodule X do
        def caller, do: helper(1)

        @doc "Internal helper"
        @spec helper(integer()) :: integer()
        def helper(n), do: n * 2
      end
      """

      {:ok, result} =
        ExtractPrivate.extract_private(source,
          definition: "helper/1",
          path: "lib/x.ex",
          files: %{"lib/x.ex" => source}
        )

      assert result.new_source =~ "@doc \"Internal helper\""
      assert result.new_source =~ "@spec helper"
      assert result.new_source =~ "defp helper(n)"
    end
  end

  describe "extract_private/2 — refusals" do
    test "already-private def returns {:already_private, ...}" do
      source = """
      defmodule X do
        defp helper(x), do: x * 2
      end
      """

      assert {:error, {:already_private, %{kind: :defp}}} =
               ExtractPrivate.extract_private(source,
                 definition: "helper/1",
                 path: "lib/x.ex",
                 files: %{"lib/x.ex" => source}
               )
    end

    test "defdelegate cannot be made private" do
      source = """
      defmodule X do
        defdelegate run(x), to: Other
      end
      """

      assert {:error, :cannot_be_private} =
               ExtractPrivate.extract_private(source,
                 definition: "run/1",
                 path: "lib/x.ex",
                 files: %{"lib/x.ex" => source}
               )
    end

    test "external caller in another file blocks the flip" do
      source = """
      defmodule MyApp.Foo do
        def helper(x), do: x * 2
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def go, do: MyApp.Foo.helper(5)
      end
      """

      assert {:error, {:external_callers, [ref]}} =
               ExtractPrivate.extract_private(source,
                 definition: "helper/1",
                 path: "lib/foo.ex",
                 files: %{"lib/foo.ex" => source, "lib/caller.ex" => caller}
               )

      assert ref.path == "lib/caller.ex"
      assert ref.line == 2
      assert ref.in_module == "MyApp.Caller"
    end

    test "external caller via alias is detected and blocks" do
      source = """
      defmodule MyApp.Foo do
        def helper(x), do: x * 2
      end
      """

      caller = """
      defmodule MyApp.Caller do
        alias MyApp.Foo
        def go, do: Foo.helper(5)
      end
      """

      assert {:error, {:external_callers, [ref]}} =
               ExtractPrivate.extract_private(source,
                 definition: "helper/1",
                 path: "lib/foo.ex",
                 files: %{"lib/foo.ex" => source, "lib/caller.ex" => caller}
               )

      assert ref.path == "lib/caller.ex"
    end

    test "sibling module in the same file blocks the flip" do
      source = """
      defmodule MyApp.Foo do
        def helper(x), do: x * 2
      end

      defmodule MyApp.Sibling do
        def go, do: MyApp.Foo.helper(5)
      end
      """

      assert {:error, {:external_callers, [ref]}} =
               ExtractPrivate.extract_private(source,
                 definition: "helper/1",
                 path: "lib/foo.ex",
                 files: %{"lib/foo.ex" => source}
               )

      assert ref.in_module == "MyApp.Sibling"
    end

    test "definition not found" do
      source = """
      defmodule X do
        def real, do: :ok
      end
      """

      assert {:error, {:not_found, :definition}} =
               ExtractPrivate.extract_private(source,
                 definition: "imaginary/0",
                 path: "lib/x.ex",
                 files: %{"lib/x.ex" => source}
               )
    end

    test "multiple modules with same def → ambiguous without --from-module" do
      source = """
      defmodule A do
        def helper(x), do: x
      end

      defmodule B do
        def helper(x), do: x + 1
      end
      """

      assert {:error, {:ambiguous_source_module, %{modules: mods}}} =
               ExtractPrivate.extract_private(source,
                 definition: "helper/1",
                 path: "lib/ab.ex",
                 files: %{"lib/ab.ex" => source}
               )

      assert "A" in mods and "B" in mods
    end

    test "--from-module disambiguates and picks one" do
      source = """
      defmodule A do
        def helper(x), do: x
        def caller, do: helper(1)
      end

      defmodule B do
        def helper(x), do: x + 1
        def caller, do: helper(1)
      end
      """

      {:ok, result} =
        ExtractPrivate.extract_private(source,
          definition: "helper/1",
          from_module: "A",
          path: "lib/ab.ex",
          files: %{"lib/ab.ex" => source}
        )

      assert result.module == "A"
      # A's helper flipped; B's helper untouched.
      lines = String.split(result.new_source, "\n")
      [a_helper_line] = Enum.filter(lines, &(&1 =~ ~r/helper\(x\), do: x$/))
      assert a_helper_line =~ "defp"
      [b_helper_line] = Enum.filter(lines, &(&1 =~ ~r/helper\(x\), do: x \+ 1/))
      assert b_helper_line =~ ~r/^\s*def /
    end
  end

  describe "extract_private/2 — capture / pipe references" do
    test "external capture &Mod.fun/n blocks the flip" do
      source = """
      defmodule MyApp.Foo do
        def helper(x), do: x * 2
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def go, do: Enum.map([1,2], &MyApp.Foo.helper/1)
      end
      """

      assert {:error, {:external_callers, [ref]}} =
               ExtractPrivate.extract_private(source,
                 definition: "helper/1",
                 path: "lib/foo.ex",
                 files: %{"lib/foo.ex" => source, "lib/caller.ex" => caller}
               )

      assert ref.kind == :capture
    end

    test "external pipe call blocks the flip" do
      source = """
      defmodule MyApp.Foo do
        def helper(x, y), do: x + y
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def go, do: 1 |> MyApp.Foo.helper(2)
      end
      """

      assert {:error, {:external_callers, [ref]}} =
               ExtractPrivate.extract_private(source,
                 definition: "helper/2",
                 path: "lib/foo.ex",
                 files: %{"lib/foo.ex" => source, "lib/caller.ex" => caller}
               )

      assert ref.arity == 2
    end
  end

  describe "Formatter.format_extract_private/2" do
    setup do
      source = """
      defmodule X do
        def caller, do: helper(1)
        def helper(n), do: n * 2
      end
      """

      {:ok, result} =
        ExtractPrivate.extract_private(source,
          definition: "helper/1",
          path: "lib/x.ex",
          files: %{"lib/x.ex" => source}
        )

      %{result: result, text: Adze.Formatter.format_extract_private(result, :text)}
    end

    test "text output names the flip and includes the diff", %{text: text} do
      assert text =~ "extract-private X.helper/1"
      assert text =~ "def → defp"
      assert text =~ "-  def helper"
      assert text =~ "+  defp helper"
    end

    test "json output is structured", %{result: result} do
      json = Adze.Formatter.format_extract_private(result, :json)
      assert {:ok, decoded} = JSON.decode(json)
      assert decoded["module"] == "X"
      assert decoded["from_kind"] == "def"
      assert decoded["to_kind"] == "defp"
      assert decoded["arity"] == 1
    end
  end
end
