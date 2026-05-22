defmodule AdzeDepsTest do
  use ExUnit.Case, async: true

  alias Adze.Deps

  @fixture Path.expand("fixtures/sample_deps.ex", __DIR__)

  describe "deps_file/1" do
    setup do
      {:ok, deps} = Deps.deps_file(@fixture)
      %{deps: deps}
    end

    test "discovers both top-level modules", %{deps: deps} do
      names = Enum.map(deps.modules, & &1.name)
      assert "SampleDeps" in names
      assert "SampleDeps.Sibling" in names
    end

    test "main/1 records all pipe-expanded local calls", %{deps: deps} do
      main = def_named(deps, "SampleDeps", :main, 1)
      assert {:double, 1} in main.calls
      assert {:add_one, 1} in main.calls
      assert {:finalize, 1} in main.calls
    end

    test "default-arg defs surface only the canonical (highest) arity", %{deps: deps} do
      # `defp helper(a, mode \\ :normal)` has one implementation that
      # Elixir compiles into helper/1 + helper/2. The graph records
      # only helper/2 (the actual head); helper/1 is synthetic and
      # resolves to helper/2 at call sites via the `defined` map.
      assert def_named(deps, "SampleDeps", :helper, 2)

      refute Enum.any?(
               mod(deps, "SampleDeps").defs,
               &(&1.name == :helper and &1.arity == 1)
             )
    end

    test "multi-clause defs surface every declared arity", %{deps: deps} do
      assert def_named(deps, "SampleDeps", :add_one, 1)
      assert def_named(deps, "SampleDeps", :add_one, 2)
    end

    test "&name/arity captures count as calls", %{deps: deps} do
      finalize = def_named(deps, "SampleDeps", :finalize, 1)
      assert {:double, 1} in finalize.calls
    end

    test "fully-qualified external calls are excluded", %{deps: deps} do
      finalize = def_named(deps, "SampleDeps", :finalize, 1)
      refute Enum.any?(finalize.calls, fn {n, _} -> n in [:thing, :map, :inspect] end)
    end

    test "private flag tracks defp", %{deps: deps} do
      refute def_named(deps, "SampleDeps", :main, 1).private
      assert def_named(deps, "SampleDeps", :double, 1).private
      assert def_named(deps, "SampleDeps", :helper, 2).private
    end

    test "helper/2 records log/1 call", %{deps: deps} do
      helper = def_named(deps, "SampleDeps", :helper, 2)
      assert {:log, 1} in helper.calls
    end

    test "every def carries a range", %{deps: deps} do
      mod = mod(deps, "SampleDeps")

      for d <- mod.defs do
        assert match?(%{start: s, end: e} when is_integer(s) and is_integer(e), d.range),
               "missing range on #{d.name}/#{d.arity}"
      end
    end

    test "leaf defs have empty calls list", %{deps: deps} do
      double = def_named(deps, "SampleDeps", :double, 1)
      assert double.calls == []

      go = def_named(deps, "SampleDeps.Sibling", :go, 0)
      assert go.calls == []
    end
  end

  describe "nested modules" do
    test "inner defmodule becomes its own scope" do
      src = """
      defmodule Outer do
        def a(x), do: helper(x)
        defp helper(x), do: x

        defmodule Inner do
          def b(x), do: helper(x)
          defp helper(x), do: x * 2
        end
      end
      """

      {:ok, deps} = Deps.deps(src)
      names = Enum.map(deps.modules, & &1.name)
      assert "Outer" in names
      assert "Outer.Inner" in names

      outer_a = def_named(deps, "Outer", :a, 1)
      assert {:helper, 1} in outer_a.calls

      inner_b = def_named(deps, "Outer.Inner", :b, 1)
      assert {:helper, 1} in inner_b.calls
    end
  end

  describe "pipe variants" do
    test "x |> foo() — parenthesised pipe is a 1-arity call" do
      src = """
      defmodule Parens do
        def caller(x), do: x |> helper()
        defp helper(x), do: x
      end
      """

      {:ok, deps} = Deps.deps(src)
      caller = def_named(deps, "Parens", :caller, 1)
      assert {:helper, 1} in caller.calls
    end

    test "x |> foo — bare pipe RHS is a 1-arity call" do
      src = """
      defmodule Bare do
        def caller(x), do: x |> helper
        defp helper(x), do: x
      end
      """

      {:ok, deps} = Deps.deps(src)
      caller = def_named(deps, "Bare", :caller, 1)
      assert {:helper, 1} in caller.calls
    end

    test "x |> foo(extra) — pipe with extra args is an N+1-arity call" do
      src = """
      defmodule Extra do
        def caller(x), do: x |> helper(:tag)
        defp helper(x, tag), do: {x, tag}
      end
      """

      {:ok, deps} = Deps.deps(src)
      caller = def_named(deps, "Extra", :caller, 1)
      assert {:helper, 2} in caller.calls
    end

    test "x |> Mod.foo — qualified pipe is still excluded" do
      src = """
      defmodule Qualified do
        def caller(x), do: x |> External.thing
        defp thing(x), do: x
      end
      """

      {:ok, deps} = Deps.deps(src)
      caller = def_named(deps, "Qualified", :caller, 1)
      assert caller.calls == []
    end
  end

  describe "default-arg canonical-arity collapse" do
    # Default-arg synthetic arities are recorded as graph nodes (both
    # foo/1 and foo/2 exist so users can query either), but call sites
    # always resolve to the canonical (highest) arity — that's the
    # actual implementation. Previously, fate-sharing recorded edges
    # to every synthetic arity, producing phantom self-loops on
    # recursive default-arg defs.

    test "call at lower arity resolves to canonical (highest) arity" do
      src = """
      defmodule DefaultArgs do
        def caller(x), do: helper(x)
        defp helper(a, b \\\\ :default), do: {a, b}
      end
      """

      {:ok, deps} = Deps.deps(src)
      caller = def_named(deps, "DefaultArgs", :caller, 1)
      assert caller.calls == [{:helper, 2}]
    end

    test "call at higher arity also resolves to the same canonical arity" do
      src = """
      defmodule DefaultArgs do
        def caller(x, y), do: helper(x, y)
        defp helper(a, b \\\\ :default), do: {a, b}
      end
      """

      {:ok, deps} = Deps.deps(src)
      caller = def_named(deps, "DefaultArgs", :caller, 2)
      assert caller.calls == [{:helper, 2}]
    end

    test "plain defs without defaults don't bleed across arities" do
      src = """
      defmodule Plain do
        def caller(x), do: helper(x)
        defp helper(x), do: x
        defp helper(x, y), do: {x, y}
      end
      """

      {:ok, deps} = Deps.deps(src)
      caller = def_named(deps, "Plain", :caller, 1)
      assert {:helper, 1} in caller.calls
      refute {:helper, 2} in caller.calls
    end

    test "multiple defaults all resolve to the canonical arity" do
      src = """
      defmodule ManyDefaults do
        def caller(x), do: helper(x)
        defp helper(a, b \\\\ 1, c \\\\ 2), do: {a, b, c}
      end
      """

      {:ok, deps} = Deps.deps(src)
      caller = def_named(deps, "ManyDefaults", :caller, 1)
      assert caller.calls == [{:helper, 3}]
    end

    test "recursive default-arg def: no phantom self-loop fan-out" do
      # `def fun(_, _, _, opts \\ [])` with a recursive call to fun/3
      # previously emitted fun/3 and fun/4 as separate nodes and
      # fate-shared the call edge — fun/4 reported outgoing edges to
      # BOTH fun/3 AND fun/4. Now the graph has one fun/4 node (the
      # canonical impl); fun/3 doesn't exist as a separate node.
      # The recursive call resolves to a single fun/4 self-edge.
      src = """
      defmodule Recursive do
        def fun(a, b, c, opts \\\\ []) do
          if opts == [] do
            fun(a, b, c, [:done])
          else
            {a, b, c, opts}
          end
        end
      end
      """

      {:ok, deps} = Deps.deps(src)
      fun4 = def_named(deps, "Recursive", :fun, 4)

      assert fun4.calls == [{:fun, 4}]
      refute Enum.any?(mod(deps, "Recursive").defs, &(&1.arity == 3))
    end

    test "call to a default-arg sibling resolves to canonical, not the synthetic arity" do
      # Even when caller arity coincides with a synthetic arity of
      # the callee, the recorded edge points to the canonical impl.
      src = """
      defmodule Cross do
        def a(x), do: b(x)
        defp b(x, y \\\\ :default), do: {x, y}
      end
      """

      {:ok, deps} = Deps.deps(src)
      assert def_named(deps, "Cross", :a, 1).calls == [{:b, 2}]
    end
  end

  describe "deps/2" do
    test "returns error tuple on parse failure" do
      assert {:error, {:parse, _}} = Deps.deps("def broken(")
    end
  end

  defp mod(deps, name) do
    Enum.find(deps.modules, &(&1.name == name)) ||
      flunk("no module #{name} in #{inspect(Enum.map(deps.modules, & &1.name))}")
  end

  defp def_named(deps, mod_name, name, arity) do
    m = mod(deps, mod_name)

    Enum.find(m.defs, &(&1.name == name and &1.arity == arity)) ||
      flunk("no #{name}/#{arity} in #{mod_name}")
  end
end
