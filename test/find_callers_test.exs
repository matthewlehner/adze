defmodule Adze.FindCallersTest do
  use ExUnit.Case, async: false

  alias Adze.FindCallers

  describe "find_callers/2 — direct calls" do
    test "finds a qualified call by fully-qualified target" do
      files = %{
        "lib/foo.ex" => """
        defmodule MyApp.Foo do
          def bar(_, _), do: :ok
        end
        """,
        "lib/caller.ex" => """
        defmodule MyApp.Caller do
          def go do
            MyApp.Foo.bar(1, 2)
          end
        end
        """
      }

      {:ok, %{target: target, total: total, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar/2", files: files)

      assert target == %{module: "MyApp.Foo", function: :bar, arity: 2}
      assert total == 1

      [%{kind: :call, arity: 2, line: line, snippet: snippet}] =
        result_files["lib/caller.ex"]

      assert line == 3
      assert snippet =~ "MyApp.Foo.bar(1, 2)"
    end

    test "tuple target form is accepted" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          def go, do: MyApp.Foo.bar(:hello)
        end
        """
      }

      {:ok, %{total: 1}} = FindCallers.find_callers({MyApp.Foo, :bar, 1}, files: files)
    end

    test "any-arity (:any) matches every arity of the target function" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          def go do
            MyApp.Foo.bar()
            MyApp.Foo.bar(1)
            MyApp.Foo.bar(1, 2)
          end
        end
        """
      }

      {:ok, %{total: total, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar", files: files)

      assert total == 3
      callers = result_files["lib/x.ex"]
      assert Enum.map(callers, & &1.arity) == [0, 1, 2]
    end

    test "arity mismatch is excluded" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          def go do
            MyApp.Foo.bar(1)
            MyApp.Foo.bar(1, 2)
          end
        end
        """
      }

      {:ok, %{total: 1, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar/2", files: files)

      [c] = result_files["lib/x.ex"]
      assert c.arity == 2
    end

    test "different function name does not match" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          def go, do: MyApp.Foo.baz(1, 2)
        end
        """
      }

      {:ok, %{total: 0, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar/2", files: files)

      assert result_files == %{}
    end
  end

  describe "find_callers/2 — pipes" do
    test "x |> Mod.fun(args) records arity + 1" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          def go(x), do: x |> MyApp.Foo.bar(2)
        end
        """
      }

      {:ok, %{total: 1, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar/2", files: files)

      [c] = result_files["lib/x.ex"]
      assert c.arity == 2
      assert c.kind == :call
    end

    test "x |> Mod.fun (no parens) records arity 1" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          def go(x), do: x |> MyApp.Foo.bar
        end
        """
      }

      {:ok, %{total: 1, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar/1", files: files)

      [c] = result_files["lib/x.ex"]
      assert c.arity == 1
    end
  end

  describe "find_callers/2 — captures" do
    test "&Mod.fun/2 records as a capture" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          def go, do: Enum.map([1,2], &MyApp.Foo.bar/2)
        end
        """
      }

      {:ok, %{total: 1, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar/2", files: files)

      [c] = result_files["lib/x.ex"]
      assert c.kind == :capture
      assert c.arity == 2
    end
  end

  describe "find_callers/2 — alias resolution" do
    test "resolves alias Foo.Bar then Bar.fun(...)" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          alias MyApp.Foo
          def go, do: Foo.bar(1, 2)
        end
        """
      }

      {:ok, %{total: 1, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar/2", files: files)

      [c] = result_files["lib/x.ex"]
      assert c.line == 3
    end

    test "resolves alias Foo, as: F then F.fun(...)" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          alias MyApp.Foo, as: F
          def go, do: F.bar(1, 2)
        end
        """
      }

      {:ok, %{total: 1, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar/2", files: files)

      [_c] = result_files["lib/x.ex"]
    end

    test "resolves brace-form alias Foo.{Bar, Baz}" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          alias MyApp.{Foo, Other}
          def go do
            Foo.bar(1, 2)
            Other.thing()
          end
        end
        """
      }

      {:ok, %{total: 1, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar/2", files: files)

      [_c] = result_files["lib/x.ex"]
    end

    test "no alias — only fully-qualified refs match" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          def go do
            MyApp.Foo.bar(1, 2)
            Foo.bar(1, 2)
          end
        end
        """
      }

      {:ok, %{total: 1, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar/2", files: files)

      [c] = result_files["lib/x.ex"]
      assert c.line == 3
    end
  end

  describe "find_callers/2 — across files" do
    test "aggregates callers from multiple files, sorted by path" do
      files = %{
        "lib/a.ex" => """
        defmodule A do
          def go, do: MyApp.Foo.bar(1, 2)
        end
        """,
        "lib/b.ex" => """
        defmodule B do
          alias MyApp.Foo
          def go, do: Foo.bar(:x, :y)
        end
        """,
        "lib/c.ex" => """
        defmodule C do
          def nothing, do: :ok
        end
        """
      }

      {:ok, %{total: 2, files: result_files}} =
        FindCallers.find_callers("MyApp.Foo.bar/2", files: files)

      assert Map.keys(result_files) |> Enum.sort() == ["lib/a.ex", "lib/b.ex"]
    end
  end

  describe "find_callers/2 — non-atom AST in __aliases__ parts" do
    # `@spec foo(__MODULE__.Inner.t()) :: ...` parses as
    # `{:__aliases__, _, [{:__MODULE__, _, nil}, :Inner]}` — the first
    # part is an AST tuple, not an atom. A single such ref anywhere in
    # the project used to crash every find-callers call with
    # `:erlang.atom_to_binary/1: not an atom`. Should now be silently
    # skipped (can't be statically resolved).
    test "spec referencing __MODULE__.Inner.t() does not crash" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          defmodule Inner do
            @type t :: map()
          end

          @spec foo(__MODULE__.Inner.t()) :: :ok
          def foo(_), do: :ok
        end
        """,
        "lib/caller.ex" => """
        defmodule Caller do
          def go, do: X.foo(%{})
        end
        """
      }

      assert {:ok, %{total: 1, files: result_files}} =
               FindCallers.find_callers("X.foo/1", files: files)

      assert Map.has_key?(result_files, "lib/caller.ex")
    end

    test "alias __MODULE__.Inner declaration resolves Inner.fun(...) calls" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          defmodule Inner do
            def thing(x), do: x
          end

          alias __MODULE__.Inner
          def go(x), do: Inner.thing(x)
        end
        """
      }

      assert {:ok, %{total: 1, files: result_files}} =
               FindCallers.find_callers("X.Inner.thing/1", files: files)

      [c] = result_files["lib/x.ex"]
      assert c.kind == :call
      assert c.snippet =~ "Inner.thing(x)"
    end

    test "captures targeting &__MODULE__.Inner.fun/arity resolve" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          defmodule Inner do
            def thing(x), do: x
          end

          def go(xs), do: Enum.map(xs, &__MODULE__.Inner.thing/1)
        end
        """
      }

      assert {:ok, %{total: 1, files: result_files}} =
               FindCallers.find_callers("X.Inner.thing/1", files: files)

      [c] = result_files["lib/x.ex"]
      assert c.kind == :capture
    end

    test "qualified __MODULE__.Inner.fun(...) call without an alias resolves" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          defmodule Inner do
            def thing(x), do: x
          end

          def go(x), do: __MODULE__.Inner.thing(x)
        end
        """
      }

      assert {:ok, %{total: 1, files: result_files}} =
               FindCallers.find_callers("X.Inner.thing/1", files: files)

      [c] = result_files["lib/x.ex"]
      assert c.kind == :call
    end
  end

  describe "find_callers/2 — limits" do
    test "unqualified call via import is NOT detected (documented limitation)" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          import MyApp.Foo
          def go, do: bar(1, 2)
        end
        """
      }

      {:ok, %{total: 0}} = FindCallers.find_callers("MyApp.Foo.bar/2", files: files)
    end

    test "dynamic apply/3 is NOT detected" do
      files = %{
        "lib/x.ex" => """
        defmodule X do
          def go, do: apply(MyApp.Foo, :bar, [1, 2])
        end
        """
      }

      {:ok, %{total: 0}} = FindCallers.find_callers("MyApp.Foo.bar/2", files: files)
    end
  end

  describe "find_callers/2 — target parsing" do
    test "bad string target returns error" do
      assert {:error, {:bad_target, "not a target"}} =
               FindCallers.find_callers("not a target", files: %{})
    end

    test "rejects lowercase module head" do
      assert {:error, {:bad_target, _}} =
               FindCallers.find_callers("foo.bar", files: %{})
    end
  end

  describe "Formatter.format_find_callers/2" do
    setup do
      files = %{
        "lib/a.ex" => """
        defmodule A do
          alias MyApp.Foo
          def go, do: Foo.bar(1, 2)
        end
        """
      }

      {:ok, result} = FindCallers.find_callers("MyApp.Foo.bar/2", files: files)
      %{result: result, text: Adze.Formatter.format_find_callers(result, :text)}
    end

    test "text output names the target and counts refs", %{text: text} do
      assert text =~ "find-callers MyApp.Foo.bar/2"
      assert text =~ "1 ref"
      assert text =~ "lib/a.ex"
      assert text =~ "call"
    end

    test "json output is structured", %{result: result} do
      json = Adze.Formatter.format_find_callers(result, :json)
      assert {:ok, decoded} = JSON.decode(json)
      assert decoded["total"] == 1
      assert decoded["target"]["module"] == "MyApp.Foo"
      assert decoded["target"]["function"] == "bar"
    end

    test "any-arity target renders as Mod.fun/*" do
      files = %{"lib/x.ex" => "defmodule X do\n  def go, do: MyApp.Foo.bar()\nend\n"}
      {:ok, result} = FindCallers.find_callers("MyApp.Foo.bar", files: files)
      text = Adze.Formatter.format_find_callers(result, :text)
      assert text =~ "MyApp.Foo.bar/*"
    end
  end
end
