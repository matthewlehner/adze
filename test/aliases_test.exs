defmodule Adze.AliasesTest do
  use ExUnit.Case, async: true

  alias Adze.Aliases

  @fixture Path.expand("fixtures/sample.ex", __DIR__)

  describe "aliases_file/1 on sample fixture" do
    setup do
      {:ok, result} = Aliases.aliases_file(@fixture)
      %{result: result}
    end

    test "finds Sample's four directives in source order", %{result: result} do
      sample = find_module(result, "Sample")
      kinds = Enum.map(sample.directives, & &1.kind)

      assert kinds == [:use, :alias, :import, :require]
    end

    test "alias target is rendered as a dotted string", %{result: result} do
      sample = find_module(result, "Sample")
      alias_entry = Enum.find(sample.directives, &(&1.kind == :alias))

      assert alias_entry.target == "Sample.Inner"
      assert alias_entry.as == nil
      assert alias_entry.group == false
    end

    test "import preserves opts in the raw text slice", %{result: result} do
      sample = find_module(result, "Sample")
      import_entry = Enum.find(sample.directives, &(&1.kind == :import))

      assert import_entry.target == "Enum"
      assert import_entry.text =~ "only: [map: 2]"
    end

    test "use carries the module target", %{result: result} do
      sample = find_module(result, "Sample")
      use_entry = Enum.find(sample.directives, &(&1.kind == :use))

      assert use_entry.target == "GenServer"
    end

    test "every directive has a line range", %{result: result} do
      sample = find_module(result, "Sample")

      for d <- sample.directives do
        assert match?(%{start: s, end: e} when is_integer(s) and is_integer(e), d.range),
               "missing range on #{inspect(d)}"
      end
    end

    test "nested modules are tracked separately", %{result: result} do
      assert find_module(result, "Sample.Inner")
    end
  end

  describe "aliases/2 — directive shapes" do
    test "alias Foo, as: Bar captures the binding override" do
      src = """
      defmodule X do
        alias Foo.Bar, as: B
      end
      """

      {:ok, result} = Aliases.aliases(src)
      [d] = find_module(result, "X").directives

      assert d.kind == :alias
      assert d.target == "Foo.Bar"
      assert d.as == "B"
      assert d.group == false
    end

    test "group form alias Foo.{A, B.C} expands to one entry per member" do
      src = """
      defmodule X do
        alias Foo.{A, B.C}
      end
      """

      {:ok, result} = Aliases.aliases(src)
      ds = find_module(result, "X").directives

      assert length(ds) == 2

      targets = Enum.map(ds, & &1.target)
      assert "Foo.A" in targets
      assert "Foo.B.C" in targets

      # Both members share the original declaration's range + text.
      assert Enum.all?(ds, & &1.group)
      assert Enum.uniq(Enum.map(ds, & &1.range)) |> length() == 1
    end

    test "import without opts" do
      src = """
      defmodule X do
        import Bitwise
      end
      """

      {:ok, result} = Aliases.aliases(src)
      [d] = find_module(result, "X").directives

      assert d.kind == :import
      assert d.target == "Bitwise"
      assert d.as == nil
    end

    test "require with opts (require Logger, level: :warn) doesn't expose as:" do
      src = """
      defmodule X do
        require Logger
        require IEx, as: I
      end
      """

      {:ok, result} = Aliases.aliases(src)
      ds = find_module(result, "X").directives

      # adze does not extract `as:` for require/import/use today.
      # The opt is still visible via `text`.
      iex = Enum.find(ds, &(&1.target == "IEx"))
      assert iex.kind == :require
      assert iex.as == nil
      assert iex.text =~ "as: I"
    end

    test "use with opts surfaces them in the text slice" do
      src = """
      defmodule X do
        use GenServer, restart: :transient
      end
      """

      {:ok, result} = Aliases.aliases(src)
      [d] = find_module(result, "X").directives

      assert d.kind == :use
      assert d.target == "GenServer"
      assert d.text =~ "restart: :transient"
    end

    test "non-directive nodes are skipped" do
      src = """
      defmodule X do
        @attr 1
        def hello, do: :world
        alias Foo
      end
      """

      {:ok, result} = Aliases.aliases(src)
      ds = find_module(result, "X").directives

      assert length(ds) == 1
      assert hd(ds).target == "Foo"
    end
  end

  describe "aliases/2 — error paths" do
    test "returns parse error on malformed source" do
      assert {:error, {:parse, _}} = Aliases.aliases("def broken(")
    end

    test "file: option flows through" do
      {:ok, result} = Aliases.aliases("defmodule X do\n  alias Foo\nend\n", file: "x.ex")
      assert result.file == "x.ex"
    end
  end

  describe "Formatter.format_aliases/2" do
    setup do
      {:ok, result} = Aliases.aliases_file(@fixture)
      %{result: result, text: Adze.Formatter.format_aliases(result, :text)}
    end

    test "text output lists every directive under its module", %{text: text} do
      assert text =~ "defmodule Sample"
      assert text =~ "use GenServer"
      assert text =~ "alias Sample.Inner"
      assert text =~ "import Enum"
      assert text =~ "require Logger"
    end

    test "json output is valid and contains directive entries", %{result: result} do
      json = Adze.Formatter.format_aliases(result, :json)
      assert {:ok, %{"modules" => mods}} = JSON.decode(json)

      sample = Enum.find(mods, &(&1["name"] == "Sample"))
      assert sample
      assert length(sample["directives"]) > 0
    end
  end

  defp find_module(result, name) do
    Enum.find(result.modules, &(&1.name == name)) ||
      flunk("no module #{name} in #{inspect(Enum.map(result.modules, & &1.name))}")
  end
end
