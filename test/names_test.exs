defmodule Adze.NamesTest do
  use ExUnit.Case, async: true

  alias Adze.Names

  defp ast(code), do: Sourceror.parse_string!(code)

  describe "defmodule_name/2" do
    test "plain aliases nest under the enclosing module" do
      assert Names.defmodule_name(ast("Inner"), "") == "Inner"
      assert Names.defmodule_name(ast("Inner"), "Foo") == "Foo.Inner"
      assert Names.defmodule_name(ast("A.B"), "Foo") == "Foo.A.B"
    end

    test "__MODULE__.Inner is absolute, not nested twice" do
      assert Names.defmodule_name(ast("__MODULE__.Inner"), "Foo") == "Foo.Inner"
      assert Names.defmodule_name(ast("__MODULE__.A.B"), "Foo.Bar") == "Foo.Bar.A.B"
    end

    test "anything unresolvable is labelled as written" do
      assert Names.defmodule_name(ast("__MODULE__.Inner"), "") == "__MODULE__.Inner"
      assert Names.defmodule_name(ast(":erl_mod"), "Foo") == ":erl_mod"
      assert Names.defmodule_name(ast("Module.concat([:a])"), "Foo") == "Module.concat([:a])"
    end
  end

  describe "module_ref/2" do
    test "resolves __MODULE__ against the current module" do
      assert Names.module_ref(ast("__MODULE__"), "Foo") == "Foo"
      assert Names.module_ref(ast("__MODULE__.Bar"), "Foo") == "Foo.Bar"
    end

    test "plain aliases are taken as written" do
      assert Names.module_ref(ast("Bar"), "Foo") == "Bar"
    end

    test "at the top level __MODULE__ is labelled as written" do
      assert Names.module_ref(ast("__MODULE__.Bar"), "") == "__MODULE__.Bar"
    end
  end

  describe "ops agree on nested __MODULE__ modules" do
    @src """
    defmodule Foo do
      alias __MODULE__.Bar
      alias __MODULE__.{A, B}
      alias __MODULE__, as: Me

      defmodule __MODULE__.Inner do
        def x, do: Foo.Bar.go(1)

        defmodule Deeper do
          def y, do: :ok
        end
      end
    end
    """

    @expected ["Foo", "Foo.Inner", "Foo.Inner.Deeper"]

    test "Definition, Deps and Aliases name the modules the same way" do
      {:ok, defs} = Adze.Definition.list(@src)
      assert defs |> Enum.map(& &1.module) |> Enum.uniq() == tl(@expected)

      {:ok, deps} = Adze.Deps.deps(@src)
      assert Enum.map(deps.modules, & &1.name) == @expected

      {:ok, aliases} = Adze.Aliases.aliases(@src)
      assert Enum.map(aliases.modules, & &1.name) == @expected
    end

    test "Aliases resolves __MODULE__-based targets" do
      {:ok, %{modules: [foo | _]}} = Adze.Aliases.aliases(@src)

      assert Enum.map(foo.directives, &{&1.target, &1.as}) == [
               {"Foo.Bar", nil},
               {"Foo.A", nil},
               {"Foo.B", nil},
               {"Foo", "Me"}
             ]
    end

    test "FindCallers reports the same in_module" do
      {:ok, %{files: %{"lib/foo.ex" => [ref]}}} =
        Adze.FindCallers.find_callers("Foo.Bar.go/1", files: %{"lib/foo.ex" => @src})

      assert ref.in_module == "Foo.Inner"
    end

    test "Outline shows the names as written" do
      {:ok, %{definitions: [foo]}} = Adze.Outline.outline(@src)
      inner = Enum.find(foo.children, &(&1[:kind] == :defmodule))

      assert inner.name == "__MODULE__.Inner"
      assert Enum.any?(foo.children, &(&1[:target] == "__MODULE__.Bar"))
    end

    test "Extract and ExtractPrivate find definitions in them" do
      assert {:ok, %{module: "Foo.Inner.Deeper"}} =
               Adze.ExtractPrivate.extract_private(@src,
                 definition: "y/0",
                 path: "lib/foo.ex",
                 files: %{"lib/foo.ex" => @src}
               )

      assert {:ok, %{source_module: "Foo.Inner.Deeper"}} =
               Adze.Extract.extract(@src, definition: "y/0", module: "Foo.Y")
    end
  end
end
