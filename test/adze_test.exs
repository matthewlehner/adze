defmodule AdzeTest do
  use ExUnit.Case, async: true

  alias Adze.Outline

  @fixture Path.expand("fixtures/sample.ex", __DIR__)

  describe "outline_file/1" do
    setup do
      {:ok, outline} = Outline.outline_file(@fixture)
      %{outline: outline}
    end

    test "finds both top-level definitions", %{outline: outline} do
      kinds = Enum.map(outline.definitions, & &1.kind)
      assert :defmodule in kinds
      assert :defprotocol in kinds
      assert :defimpl in kinds
    end

    test "Sample module includes expected child kinds", %{outline: outline} do
      sample = find_definition(outline, :defmodule, "Sample")
      kinds = Enum.map(sample.children, & &1.kind) |> Enum.uniq()

      for expected <- [
            :use,
            :alias,
            :import,
            :require,
            :attribute,
            :defstruct,
            :def,
            :defp,
            :defmacro,
            :defguard,
            :defdelegate,
            :defmodule
          ] do
        assert expected in kinds, "missing #{expected} in #{inspect(kinds)}"
      end
    end

    test "def heads carry name + arity + private flag", %{outline: outline} do
      sample = find_definition(outline, :defmodule, "Sample")

      greets = for c <- sample.children, c[:name] == :greet, do: c
      assert length(greets) == 2
      assert Enum.all?(greets, &(&1.arity == 1))
      assert Enum.any?(greets, & &1.guards)

      internal = Enum.find(sample.children, &(&1[:name] == :internal))
      assert internal.private
      assert internal.arity == 1
    end

    test "nested defmodule appears as a child with its own children", %{outline: outline} do
      sample = find_definition(outline, :defmodule, "Sample")
      inner = Enum.find(sample.children, &(&1.kind == :defmodule and &1.name == "Inner"))

      assert inner
      assert Enum.any?(inner.children, &(&1[:name] == :hello and &1.kind == :def))
      assert Enum.any?(inner.children, &(&1[:name] == :helper and &1.kind == :defp))
    end

    test "all definitions have a line range", %{outline: outline} do
      sample = find_definition(outline, :defmodule, "Sample")

      assert match?(%{start: s, end: e} when is_integer(s) and is_integer(e), sample.range)

      for child <- sample.children do
        assert match?(%{start: s, end: e} when is_integer(s) and is_integer(e), child.range),
               "missing range on #{inspect(child)}"
      end
    end

    test "defstruct fields", %{outline: outline} do
      sample = find_definition(outline, :defmodule, "Sample")
      struct_def = Enum.find(sample.children, &(&1.kind == :defstruct))
      assert struct_def.fields == [:id, :name, :count]
    end

    test "@spec attribute targets the function name", %{outline: outline} do
      sample = find_definition(outline, :defmodule, "Sample")
      spec = Enum.find(sample.children, &(&1.kind == :attribute and &1.name == :spec))
      assert spec.target == :greet
    end
  end

  describe "outline/2" do
    test "returns error tuple on parse failure" do
      assert {:error, {:parse, _}} = Outline.outline("def broken(")
    end
  end

  describe "ls text rendering of @spec / @type targets" do
    # `@type list_args :: keyword()` rendered as `@type :list_args`
    # because the formatter called `inspect` on the target atom. We
    # want the bare identifier (the type/function name).
    setup do
      source = """
      defmodule X do
        @type list_args :: keyword()
        @spec call(list_args()) :: :ok
        def call(_), do: :ok
      end
      """

      {:ok, outline} = Adze.Outline.outline(source)
      %{text: Adze.Formatter.format(outline, :text)}
    end

    test "@type renders the bare name without atom colon", %{text: text} do
      assert text =~ ~r/^\s*@type list_args   /m
      refute text =~ "@type :list_args"
    end

    test "@spec renders the bare function name without atom colon", %{text: text} do
      assert text =~ ~r/^\s*@spec call   /m
      refute text =~ "@spec :call"
    end
  end

  describe "ls text rendering distinguishes private macros/guards" do
    @macro_fixture Path.expand("fixtures/macro_kinds.ex", __DIR__)

    setup do
      {:ok, outline} = Outline.outline_file(@macro_fixture)
      %{text: Adze.Formatter.format(outline, :text)}
    end

    test "defmacro uses `m` prefix, no private tag", %{text: text} do
      assert text =~ ~r/^\s*m pub_macro\/1   /m
      refute text =~ ~r/^\s*m pub_macro\/1 \[private\]/m
    end

    test "defmacrop uses `m` prefix plus [private] tag", %{text: text} do
      assert text =~ ~r/^\s*m priv_macro\/1 \[private\]   /m
      refute text =~ ~r/^\s*p priv_macro\/1/m
    end

    test "defguard uses `g` prefix, no private tag", %{text: text} do
      assert text =~ ~r/^\s*g pub_guard\/1 when …   /m
    end

    test "defguardp uses `g` prefix plus [private] tag", %{text: text} do
      assert text =~ ~r/^\s*g priv_guard\/1 when … \[private\]   /m
      refute text =~ ~r/^\s*p priv_guard\/1/m
    end
  end

  defp find_definition(outline, kind, name) do
    Enum.find(outline.definitions, &(&1.kind == kind and &1.name == name)) ||
      flunk("no #{kind} #{name} in #{inspect(Enum.map(outline.definitions, & &1[:name]))}")
  end
end
