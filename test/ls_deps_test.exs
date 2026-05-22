defmodule AdzeLsDepsTest do
  use ExUnit.Case, async: true

  alias Adze.LsDeps

  @fixture Path.expand("fixtures/sample_deps.ex", __DIR__)

  describe "ls_deps_file/2 on the sample fixture" do
    setup do
      {:ok, result} = LsDeps.ls_deps_file(@fixture, {:main, 1})
      %{result: result, mod: hd(result.modules)}
    end

    test "scopes to the module containing the definition", %{result: result} do
      assert [%{name: "SampleDeps"}] = result.modules
    end

    test "root is the requested definition", %{mod: mod} do
      assert mod.root.name == :main
      assert mod.root.arity == 1
      assert mod.root.repeat == false
    end

    test "root's direct children are sorted, intra-module-only calls", %{mod: mod} do
      kids = Enum.map(mod.root.children, &{&1.name, &1.arity})
      assert kids == [{:add_one, 1}, {:double, 1}, {:finalize, 1}]
    end

    test "leaf nodes are marked", %{mod: mod} do
      add_one = Enum.find(mod.root.children, &(&1.name == :add_one))
      assert add_one.leaf == true
      assert add_one.children == []
    end

    test "diamond / re-encountered nodes are collapsed with repeat: true", %{mod: mod} do
      finalize = Enum.find(mod.root.children, &(&1.name == :finalize))
      double_under_finalize = Enum.find(finalize.children, &(&1.name == :double))

      # double/1 was visited as a direct child of main/1 first, so the second
      # visit (as a child of finalize/1) is marked and not re-expanded.
      assert double_under_finalize.repeat == true
      assert double_under_finalize.children == []
    end

    test "log/1 expands once and is marked on subsequent visits", %{mod: mod} do
      finalize = Enum.find(mod.root.children, &(&1.name == :finalize))
      # Under the canonical-arity collapse, finalize's call to
      # `helper(x, :default)` resolves only to helper/2 (the actual
      # implementation). helper/1 — Elixir's auto-derived synthetic
      # head — is no longer surfaced as a separate node.
      helper_two = Enum.find(finalize.children, &(&1.name == :helper and &1.arity == 2))
      refute Enum.any?(finalize.children, &(&1.name == :helper and &1.arity == 1))

      # Finalize's children are sorted: {double, helper, log}. double
      # was already visited under main/1 (so it's repeat here);
      # helper/2 expands and fully visits log/1 in the process;
      # finalize's own direct log/1 child then arrives as repeat.
      log_under_helper = Enum.find(helper_two.children, &(&1.name == :log))
      assert log_under_helper.repeat == false
      assert log_under_helper.leaf == true

      log_direct = Enum.find(finalize.children, &(&1.name == :log))
      assert log_direct.repeat == true
    end

    test "private flag rides through to tree nodes", %{mod: mod} do
      refute mod.root.private
      finalize = Enum.find(mod.root.children, &(&1.name == :finalize))
      assert finalize.private
    end
  end

  describe "ls_deps for a definition in two modules" do
    test "surfaces a tree per containing module" do
      src = """
      defmodule A do
        def go(x), do: helper(x)
        defp helper(x), do: x
      end

      defmodule B do
        def go, do: :b
      end
      """

      {:ok, result} = LsDeps.ls_deps(src, {:go, 0})
      assert [%{name: "B"}] = result.modules
      assert result.modules |> hd() |> Map.get(:root) |> Map.get(:leaf)
    end

    test "returns an empty modules list when no module has the definition" do
      src = "defmodule A do\n  def a, do: :ok\nend\n"
      {:ok, result} = LsDeps.ls_deps(src, {:missing, 1})
      assert result.modules == []
    end
  end

  describe "self-recursive definitions" do
    test "the recursive call back to self is marked repeat" do
      src = """
      defmodule R do
        def loop(0), do: :done
        def loop(n), do: loop(n - 1)
      end
      """

      {:ok, result} = LsDeps.ls_deps(src, {:loop, 1})
      [%{root: root}] = result.modules
      [self_call] = root.children
      assert self_call.name == :loop
      assert self_call.repeat == true
    end
  end

  describe "ls_extract_file/2 on the sample fixture" do
    setup do
      {:ok, result} = LsDeps.ls_extract_file(@fixture, {:main, 1})
      %{result: result, mod: hd(result.modules)}
    end

    test "target is recorded", %{mod: mod} do
      assert mod.target == {:main, 1}
    end

    test "closure pulls in every defp transitively but exclusively used", %{mod: mod} do
      names = Enum.map(mod.closure, &{&1.name, &1.arity})

      assert {:main, 1} in names
      assert {:finalize, 1} in names
      assert {:double, 1} in names
      # `defp helper(a, mode \\ :normal)` registers helper/1 and helper/2
      # as graph nodes, but only helper/2 — the canonical impl — appears
      # in the closure. When extracted, Elixir's compile-time default-arg
      # expansion re-derives helper/1 in the new module automatically.
      assert {:helper, 2} in names
      refute {:helper, 1} in names
      assert {:log, 1} in names
    end

    test "public siblings are never pulled in, even if reachable", %{mod: mod} do
      names = Enum.map(mod.closure, &{&1.name, &1.arity})
      refute {:add_one, 1} in names
      refute {:add_one, 2} in names
    end

    test "closure entries carry kind, private flag, and range", %{mod: mod} do
      finalize = Enum.find(mod.closure, &(&1.name == :finalize))
      assert finalize.kind == :defp
      assert finalize.private
      assert %{start: _, end: _} = finalize.range
    end

    test "closure is ordered by source position", %{mod: mod} do
      starts = Enum.map(mod.closure, &(&1.range.start))
      assert starts == Enum.sort(starts)
    end
  end

  describe "ls_extract exclusivity rule" do
    test "a defp also called by a public sibling outside the closure is excluded" do
      src = """
      defmodule X do
        def target(x), do: shared(x)
        def other(x), do: shared(x)
        defp shared(x), do: x
      end
      """

      {:ok, result} = LsDeps.ls_extract(src, {:target, 1})
      [mod] = result.modules
      names = Enum.map(mod.closure, &{&1.name, &1.arity})

      # `shared/1` has a caller (other/1) outside the closure — exclude it.
      assert {:target, 1} in names
      refute {:shared, 1} in names
      refute {:other, 1} in names
    end

    test "a fixed point unlocks defps whose only callers were previously outside" do
      src = """
      defmodule Y do
        def target(x), do: helper_a(x)
        defp helper_a(x), do: helper_b(x)
        defp helper_b(x), do: x
      end
      """

      {:ok, result} = LsDeps.ls_extract(src, {:target, 1})
      [mod] = result.modules
      names = Enum.map(mod.closure, &{&1.name, &1.arity})

      assert {:target, 1} in names
      assert {:helper_a, 1} in names
      assert {:helper_b, 1} in names
    end

    test "private target itself is included" do
      src = """
      defmodule Z do
        def public_caller, do: priv_target()
        defp priv_target, do: :ok
      end
      """

      {:ok, result} = LsDeps.ls_extract(src, {:priv_target, 0})
      [mod] = result.modules
      names = Enum.map(mod.closure, &{&1.name, &1.arity})
      assert {:priv_target, 0} in names
    end

    test "self-recursive defp is pulled into the closure" do
      src = """
      defmodule SelfRec do
        def target(x), do: loop(x, 0)
        defp loop(0, acc), do: acc
        defp loop(n, acc), do: loop(n - 1, acc + 1)
      end
      """

      {:ok, result} = LsDeps.ls_extract(src, {:target, 1})
      [mod] = result.modules
      names = Enum.map(mod.closure, &{&1.name, &1.arity})

      assert {:target, 1} in names
      assert {:loop, 2} in names
    end

    test "mutually-recursive defps (ping/pong) are both pulled into the closure" do
      # Regression for the SCC bug: previously the iterative grower stalled
      # because each member of the cycle required the other to be in the
      # closure first.
      src = """
      defmodule MutualRec do
        def entry(x), do: ping(x, 3)
        defp ping(x, 0), do: x
        defp ping(x, n), do: pong(x + 1, n - 1)
        defp pong(x, 0), do: x
        defp pong(x, n), do: ping(x + 1, n - 1)
      end
      """

      {:ok, result} = LsDeps.ls_extract(src, {:entry, 1})
      [mod] = result.modules
      names = Enum.map(mod.closure, &{&1.name, &1.arity})

      assert {:entry, 1} in names
      assert {:ping, 2} in names
      assert {:pong, 2} in names
    end

    test "3-cycle of defps is pulled in atomically" do
      src = """
      defmodule ThreeCycle do
        def entry(x), do: a(x)
        defp a(x), do: b(x)
        defp b(x), do: c(x)
        defp c(x), do: a(x + 1)
      end
      """

      {:ok, result} = LsDeps.ls_extract(src, {:entry, 1})
      [mod] = result.modules
      names = Enum.map(mod.closure, &{&1.name, &1.arity})

      assert {:a, 1} in names
      assert {:b, 1} in names
      assert {:c, 1} in names
    end

    test "cycle with one member also called outside the closure stays out" do
      # ping/pong cycle, but pong/2 is also called by a public sibling
      # outside the closure. The whole SCC must be excluded — including
      # ping, which is otherwise exclusively the closure's.
      src = """
      defmodule MixedRec do
        def target(x), do: ping(x, 3)
        def other(x), do: pong(x, 0)
        defp ping(x, 0), do: x
        defp ping(x, n), do: pong(x + 1, n - 1)
        defp pong(x, 0), do: x
        defp pong(x, n), do: ping(x + 1, n - 1)
      end
      """

      {:ok, result} = LsDeps.ls_extract(src, {:target, 1})
      [mod] = result.modules
      names = Enum.map(mod.closure, &{&1.name, &1.arity})

      assert {:target, 1} in names
      refute {:ping, 2} in names
      refute {:pong, 2} in names
    end
  end

  describe "error passthrough" do
    test "parse failure surfaces as {:error, {:parse, _}}" do
      assert {:error, {:parse, _}} = LsDeps.ls_deps("def broken(", {:x, 0})
      assert {:error, {:parse, _}} = LsDeps.ls_extract("def broken(", {:x, 0})
    end

    test "missing file surfaces as {:error, {:file_read, _}}" do
      assert {:error, {:file_read, _}} = LsDeps.ls_deps_file("/no/such.ex", {:x, 0})
    end
  end
end
