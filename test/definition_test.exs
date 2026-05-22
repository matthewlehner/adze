defmodule AdzeDefinitionTest do
  use ExUnit.Case, async: true

  alias Adze.Definition

  defp first(source) do
    {:ok, [d | _]} = Definition.list(source)
    d
  end

  describe "find/2" do
    test "locates by name/arity string" do
      source = """
      defmodule Foo do
        def hello(name), do: "hi " <> name
      end
      """

      {:ok, def_} = Definition.find(source, "hello/1")
      assert def_.name == :hello
      assert def_.arity == 1
      assert def_.kind == :def
      assert def_.visibility == :public
      assert def_.module == "Foo"
    end

    test "accepts {atom, arity} tuple" do
      source = "defmodule X do\n  def foo, do: :ok\nend\n"
      {:ok, def_} = Definition.find(source, {:foo, 0})
      assert def_.name == :foo
    end

    test "returns :not_found for missing definition" do
      source = "defmodule X do\n  def foo, do: :ok\nend\n"
      assert Definition.find(source, "bar/0") == {:error, :not_found}
    end

    test "rejects malformed definition spec" do
      source = "defmodule X do\nend\n"
      assert {:error, {:bad_definition_spec, "junk"}} = Definition.find(source, "junk")
      assert {:error, {:bad_definition_spec, "foo/abc"}} = Definition.find(source, "foo/abc")
    end
  end

  describe "list/1 — base shapes" do
    test "bare def has no attrs, no comments" do
      source = """
      defmodule X do
        def foo, do: :ok
      end
      """

      d = first(source)
      assert d.parts.attributes == []
      assert d.parts.leading_comments == []
      assert length(d.parts.clauses) == 1
    end

    test "def + @spec attaches the spec" do
      source = """
      defmodule X do
        @spec foo() :: :ok
        def foo, do: :ok
      end
      """

      d = first(source)
      assert [{:spec, _}] = d.parts.attributes
      assert length(d.parts.clauses) == 1
    end

    test "def + @spec + @doc attaches both in source order" do
      source = """
      defmodule X do
        @doc "the doc"
        @spec foo() :: :ok
        def foo, do: :ok
      end
      """

      d = first(source)
      assert [{:doc, _}, {:spec, _}] = d.parts.attributes
    end

    test "blank line between @spec and def does not break the group" do
      source = """
      defmodule X do
        @spec foo() :: :ok

        def foo, do: :ok
      end
      """

      d = first(source)
      assert [{:spec, _}] = d.parts.attributes
    end

    test "leading comment block above def attaches via def's meta" do
      source = """
      defmodule X do
        # explainer line 1
        # explainer line 2
        def foo, do: :ok
      end
      """

      d = first(source)
      texts = Enum.map(d.parts.leading_comments, & &1.text)
      assert texts == ["# explainer line 1", "# explainer line 2"]
    end

    test "leading comments above @doc are collected (attached to @doc, not def)" do
      source = """
      defmodule X do
        # why foo exists
        @doc "the doc"
        def foo, do: :ok
      end
      """

      d = first(source)
      texts = Enum.map(d.parts.leading_comments, & &1.text)
      assert "# why foo exists" in texts
    end
  end

  describe "list/1 — multi-clause" do
    test "contiguous clauses with same {kind, name, arity} merge into one definition" do
      source = """
      defmodule X do
        @doc "foo"
        def foo(1), do: :one
        def foo(2), do: :two
        def foo(n) when n > 2, do: :many
      end
      """

      {:ok, defs} = Definition.list(source)
      assert length(defs) == 1
      [d] = defs
      assert d.name == :foo
      assert d.arity == 1
      assert length(d.parts.clauses) == 3
      assert [{:doc, _}] = d.parts.attributes
    end

    test "unrelated node between clauses splits the group" do
      source = """
      defmodule X do
        def foo(1), do: :one
        def bar, do: :ok
        def foo(2), do: :two
      end
      """

      {:ok, defs} = Definition.list(source)
      assert length(defs) == 3
      assert Enum.map(defs, & &1.name) == [:foo, :bar, :foo]
      assert Enum.map(defs, &length(&1.parts.clauses)) == [1, 1, 1]
    end

    test "attribute between clauses splits the group" do
      source = """
      defmodule X do
        def foo(1), do: :one
        @doc "second clause's doc"
        def foo(2), do: :two
      end
      """

      {:ok, defs} = Definition.list(source)
      assert length(defs) == 2
      assert Enum.at(defs, 0).parts.attributes == []
      assert [{:doc, _}] = Enum.at(defs, 1).parts.attributes
    end

    test "def + defp with same name/arity are separate (different kinds)" do
      source = """
      defmodule X do
        def foo, do: :public
        defp foo, do: :private
      end
      """

      {:ok, defs} = Definition.list(source)
      assert length(defs) == 2
      [pub, priv] = defs
      assert pub.kind == :def
      assert pub.visibility == :public
      assert priv.kind == :defp
      assert priv.visibility == :private
    end
  end

  describe "list/1 — boundaries" do
    test "def preceded by an unrelated module-level node starts fresh" do
      source = """
      defmodule X do
        alias Foo.Bar

        def foo, do: :ok
      end
      """

      d = first(source)
      assert d.parts.attributes == []
    end

    test "non-allowlisted attribute alone before def is not attached, not ambiguous" do
      source = """
      defmodule X do
        @some_const 5
        def foo, do: :ok
      end
      """

      d = first(source)
      assert d.parts.attributes == []
    end

    test "stray @doc with no following def is dropped" do
      source = """
      defmodule X do
        @doc "orphan"
        alias Foo.Bar
        def foo, do: :ok
      end
      """

      d = first(source)
      assert d.parts.attributes == []
    end
  end

  describe "list/1 — nested modules" do
    test "nested defmodule defs are scoped by qualified module name" do
      source = """
      defmodule Outer do
        def top, do: :ok

        defmodule Inner do
          def bottom, do: :ok
        end
      end
      """

      {:ok, defs} = Definition.list(source)
      modules = Enum.map(defs, &{&1.module, &1.name})
      assert {"Outer", :top} in modules
      assert {"Outer.Inner", :bottom} in modules
    end
  end

  describe "list/1 — ambiguity" do
    test "non-allowlisted attr between @spec and def raises ambiguous_attribute" do
      source = """
      defmodule X do
        @spec foo() :: :ok
        @some_const 5
        def foo, do: :ok
      end
      """

      assert {:error, {:ambiguous_attribute, info}} = Definition.list(source)
      assert info.def.name == :foo
      assert info.def.arity == 0
      assert Enum.map(info.attributes, & &1.name) == [:spec]
      assert Enum.map(info.intervening, & &1.name) == [:some_const]
    end

    test "non-allowlisted attr surrounded by allowlisted ones still raises" do
      source = """
      defmodule X do
        @spec foo() :: :ok
        @some_const 5
        @doc "..."
        def foo, do: :ok
      end
      """

      assert {:error, {:ambiguous_attribute, info}} = Definition.list(source)
      attrs = info.attributes |> Enum.map(& &1.name) |> Enum.sort()
      assert attrs == [:doc, :spec]
      assert Enum.map(info.intervening, & &1.name) == [:some_const]
    end

    test "multiple intervening attrs are all reported in source order" do
      source = """
      defmodule X do
        @spec foo() :: :ok
        @job [queue: :default]
        @dialyzer {:nowarn_function, foo: 0}
        def foo, do: :ok
      end
      """

      assert {:error, {:ambiguous_attribute, info}} = Definition.list(source)
      assert Enum.map(info.intervening, & &1.name) == [:job, :dialyzer]
      lines = Enum.map(info.intervening, & &1.line)
      assert lines == Enum.sort(lines)
    end

    test "intervening attrs carry line numbers" do
      source = """
      defmodule X do
        @spec foo() :: :ok
        @some_const 5
        def foo, do: :ok
      end
      """

      assert {:error, {:ambiguous_attribute, info}} = Definition.list(source)
      [%{line: line}] = info.intervening
      assert line == 3
    end

    test "non-allowlisted attr without pending allowlisted attrs is not intervening" do
      source = """
      defmodule X do
        @some_const 5
        def foo, do: :ok
      end
      """

      {:ok, [d]} = Definition.list(source)
      assert d.parts.attributes == []
    end
  end

  describe "list/1 — type / callback consumers" do
    test "@typedoc + @type alone produces no error and no definitions" do
      source = """
      defmodule X do
        @typedoc "an id"
        @type id :: integer()
      end
      """

      assert {:ok, []} = Definition.list(source)
    end

    test "@doc + @callback alone produces no error and no definitions" do
      source = """
      defmodule X do
        @doc "set up the thing"
        @callback init() :: :ok
      end
      """

      assert {:ok, []} = Definition.list(source)
    end

    test "@type/@callback absorbs preceding attrs; later def gets its own attrs" do
      source = """
      defmodule X do
        @typedoc "id"
        @type id :: integer()

        @doc "foo doc"
        @spec foo() :: :ok
        def foo, do: :ok
      end
      """

      {:ok, [d]} = Definition.list(source)
      assert d.name == :foo
      attrs = d.parts.attributes |> Enum.map(fn {n, _} -> n end)
      assert attrs == [:doc, :spec]
    end

    test "@callback between defs does not poison the next def" do
      source = """
      defmodule X do
        def first, do: :ok

        @doc "implementing callback"
        @callback do_thing() :: :ok

        @spec second() :: :ok
        def second, do: :ok
      end
      """

      {:ok, defs} = Definition.list(source)
      names = Enum.map(defs, & &1.name)
      assert names == [:first, :second]

      second = Enum.find(defs, &(&1.name == :second))
      assert [{:spec, _}] = second.parts.attributes
    end

    test "@type with no preceding attrs and following @typedoc still works" do
      source = """
      defmodule X do
        @type a :: integer()
        @typedoc "b"
        @type b :: atom()
      end
      """

      assert {:ok, []} = Definition.list(source)
    end

    test "@opaque, @typep, @macrocallback are all consumers" do
      source = """
      defmodule X do
        @typedoc "secret"
        @opaque secret :: term()

        @typedoc "internal"
        @typep internal :: atom()

        @doc "a macro callback"
        @macrocallback build(term()) :: Macro.t()

        @spec foo() :: :ok
        def foo, do: :ok
      end
      """

      {:ok, [d]} = Definition.list(source)
      assert d.name == :foo
      assert [{:spec, _}] = d.parts.attributes
    end
  end

  describe "list/1 — visibility + kind" do
    test "defp, defmacro, defmacrop, defguard, defguardp, defdelegate all surface" do
      source = """
      defmodule X do
        def a, do: :ok
        defp b, do: :ok
        defmacro c, do: :ok
        defmacrop d, do: :ok
        defguard e(x) when is_atom(x)
        defguardp f(x) when is_atom(x)
        defdelegate g(x), to: Kernel, as: :inspect
      end
      """

      {:ok, defs} = Definition.list(source)
      pairs = Enum.map(defs, &{&1.name, &1.kind, &1.visibility})

      assert {:a, :def, :public} in pairs
      assert {:b, :defp, :private} in pairs
      assert {:c, :defmacro, :public} in pairs
      assert {:d, :defmacrop, :private} in pairs
      assert {:e, :defguard, :public} in pairs
      assert {:f, :defguardp, :private} in pairs
      assert {:g, :defdelegate, :public} in pairs
    end
  end

  describe "list/1 — range" do
    test "range spans from earliest leading comment to last clause" do
      source = """
      defmodule X do
        # comment line 2
        @doc "doc line 3"
        def foo(1), do: :one
        def foo(2), do: :two
      end
      """

      d = first(source)
      assert %Sourceror.Range{start: start_kw, end: end_kw} = d.range
      assert Keyword.fetch!(start_kw, :line) == 2
      assert Keyword.fetch!(end_kw, :line) == 5
    end

    test "bare def range starts at the def line" do
      source = """
      defmodule X do
        def foo, do: :ok
      end
      """

      d = first(source)
      assert Keyword.fetch!(d.range.start, :line) == 2
    end
  end

  describe "list/2 — include_attrs widens the allowlist" do
    test "without include_attrs, @job between @spec and def raises" do
      source = """
      defmodule X do
        @spec foo() :: :ok
        @job [queue: :default]
        def foo, do: :ok
      end
      """

      assert {:error, {:ambiguous_attribute, _}} = Definition.list(source)
    end

    test "with include_attrs: [:job], @job is attachable and no error" do
      source = """
      defmodule X do
        @spec foo() :: :ok
        @job [queue: :default]
        def foo, do: :ok
      end
      """

      {:ok, [d]} = Definition.list(source, include_attrs: [:job])
      assert d.name == :foo
      attr_names = d.parts.attributes |> Enum.map(fn {n, _} -> n end)
      assert attr_names == [:spec, :job]
    end

    test "multiple include_attrs work in combination" do
      source = """
      defmodule X do
        @doc "first"
        @job [queue: :default]
        @decorate trace()
        @spec foo() :: :ok
        def foo, do: :ok
      end
      """

      {:ok, [d]} = Definition.list(source, include_attrs: [:job, :decorate])
      attr_names = d.parts.attributes |> Enum.map(fn {n, _} -> n end)
      assert attr_names == [:doc, :job, :decorate, :spec]
    end

    test "include_attrs is per-call; default behavior is unchanged" do
      source = """
      defmodule X do
        @spec foo() :: :ok
        @job [queue: :default]
        def foo, do: :ok
      end
      """

      {:ok, [_]} = Definition.list(source, include_attrs: [:job])
      assert {:error, {:ambiguous_attribute, info}} = Definition.list(source)
      assert Enum.map(info.intervening, & &1.name) == [:job]
    end

    test "find/3 accepts include_attrs and threads it through" do
      source = """
      defmodule X do
        @spec foo() :: :ok
        @decorate trace()
        def foo, do: :ok
      end
      """

      assert {:error, {:ambiguous_attribute, _}} = Definition.find(source, "foo/0")

      {:ok, d} = Definition.find(source, "foo/0", include_attrs: [:decorate])
      attr_names = d.parts.attributes |> Enum.map(fn {n, _} -> n end)
      assert attr_names == [:spec, :decorate]
    end

    test "non-atom entries in include_attrs are silently ignored" do
      source = """
      defmodule X do
        @spec foo() :: :ok
        def foo, do: :ok
      end
      """

      {:ok, [d]} = Definition.list(source, include_attrs: ["job", 42, :impl])
      assert [{:spec, _}] = d.parts.attributes
    end
  end

  describe "find/2 + nested modules" do
    test "returns the first match across modules" do
      source = """
      defmodule Outer do
        def foo, do: :outer
        defmodule Inner do
          def foo, do: :inner
        end
      end
      """

      {:ok, d} = Definition.find(source, "foo/0")
      assert d.module == "Outer"
    end
  end
end
