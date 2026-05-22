defmodule AdzeTypesTest do
  use ExUnit.Case, async: true

  alias Adze.Types

  defp body_nodes(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    {:defmodule, _, [_, [{_, body}]]} = ast

    case body do
      {:__block__, _, exprs} -> exprs
      single -> [single]
    end
  end

  defp specs_in(source) do
    body_nodes(source)
    |> Enum.filter(fn
      {:@, _, [{:spec, _, _}]} -> true
      _ -> false
    end)
  end

  describe "index/1" do
    test "indexes @type / @typep / @opaque with arities and visibility" do
      src = """
      defmodule M do
        @type t :: %__MODULE__{}
        @type id :: pos_integer()
        @type result(a) :: {:ok, a} | {:error, term()}
        @typep state :: :idle | :running
        @opaque token :: binary
      end
      """

      idx = Types.index(body_nodes(src))

      assert idx[{:t, 0}] == :public
      assert idx[{:id, 0}] == :public
      assert idx[{:result, 1}] == :public
      assert idx[{:state, 0}] == :private
      assert idx[{:token, 0}] == :public
    end

    test "returns an empty map when there are no type declarations" do
      src = "defmodule M do\n  def f, do: :ok\nend\n"
      assert Types.index(body_nodes(src)) == %{}
    end
  end

  describe "references_local?/2" do
    test "true when the @spec mentions a local type" do
      src = """
      defmodule M do
        @type t :: integer
        @spec foo() :: t()
      end
      """

      idx = Types.index(body_nodes(src))
      [spec] = specs_in(src)
      assert Types.references_local?(spec, idx)
    end

    test "false for fully built-in types" do
      src = """
      defmodule M do
        @type t :: integer
        @spec foo(integer) :: pos_integer
      end
      """

      idx = Types.index(body_nodes(src))
      [spec] = specs_in(src)
      refute Types.references_local?(spec, idx)
    end

    test "false for already-qualified types in another module" do
      src = """
      defmodule M do
        @type t :: integer
        @spec foo() :: String.t()
      end
      """

      idx = Types.index(body_nodes(src))
      [spec] = specs_in(src)
      refute Types.references_local?(spec, idx)
    end

    test "false when index is empty" do
      src = "defmodule M do\n  @spec foo() :: t()\n  def foo, do: nil\nend\n"
      [spec] = specs_in(src)
      refute Types.references_local?(spec, %{})
    end
  end

  describe "qualify/3 — @spec rewriting" do
    test "qualifies a bare arity-0 type call in the return" do
      src = """
      defmodule MyApp.Source do
        @type t :: integer
        @spec foo() :: t()
      end
      """

      idx = Types.index(body_nodes(src))
      [spec] = specs_in(src)
      qualified = Types.qualify(spec, idx, "MyApp.Source")

      rendered = Sourceror.to_string(qualified)
      assert rendered =~ ~r/MyApp\.Source\.t\(\)/
    end

    test "qualifies bare type calls inside @spec head args" do
      src = """
      defmodule MyApp.Source do
        @type id :: pos_integer
        @spec fetch(id()) :: :ok
      end
      """

      idx = Types.index(body_nodes(src))
      [spec] = specs_in(src)
      rendered = spec |> Types.qualify(idx, "MyApp.Source") |> Sourceror.to_string()

      assert rendered =~ ~r/fetch\(MyApp\.Source\.id\(\)\)/
      # the function name itself is NOT rewritten
      refute rendered =~ ~r/MyApp\.Source\.fetch/
    end

    test "qualifies recursively into parameterized types" do
      src = """
      defmodule MyApp.Source do
        @type id :: pos_integer
        @type wrap(a) :: {:ok, a}
        @spec build() :: wrap(id())
      end
      """

      idx = Types.index(body_nodes(src))
      [spec] = specs_in(src)
      rendered = spec |> Types.qualify(idx, "MyApp.Source") |> Sourceror.to_string()

      assert rendered =~ ~r/MyApp\.Source\.wrap\(MyApp\.Source\.id\(\)\)/
    end

    test "leaves already-qualified type calls intact" do
      src = """
      defmodule MyApp.Source do
        @type t :: integer
        @spec wrap(String.t(), [MyApp.Other.id()]) :: {:ok, t()} | :error
      end
      """

      idx = Types.index(body_nodes(src))
      [spec] = specs_in(src)
      rendered = spec |> Types.qualify(idx, "MyApp.Source") |> Sourceror.to_string()

      # local t() got qualified
      assert rendered =~ ~r/MyApp\.Source\.t\(\)/
      # pre-qualified refs are untouched
      assert rendered =~ ~r/String\.t\(\)/
      assert rendered =~ ~r/MyApp\.Other\.id\(\)/
      # no double-qualification
      refute rendered =~ ~r/MyApp\.Source\.String/
      refute rendered =~ ~r/MyApp\.Source\.MyApp\.Other/
    end

    test "leaves built-in types alone" do
      src = """
      defmodule MyApp.Source do
        @type t :: integer
        @spec foo(integer, binary) :: pos_integer | {:ok, t()} | :error
      end
      """

      idx = Types.index(body_nodes(src))
      [spec] = specs_in(src)
      rendered = spec |> Types.qualify(idx, "MyApp.Source") |> Sourceror.to_string()

      assert rendered =~ ~r/MyApp\.Source\.t\(\)/
      refute rendered =~ ~r/MyApp\.Source\.integer/
      refute rendered =~ ~r/MyApp\.Source\.binary/
      refute rendered =~ ~r/MyApp\.Source\.pos_integer/
    end

    test "throws :typep_referenced when @spec uses a @typep" do
      src = """
      defmodule MyApp.Source do
        @typep state :: :idle | :running
        @spec snapshot() :: state()
      end
      """

      idx = Types.index(body_nodes(src))
      [spec] = specs_in(src)

      assert catch_throw(Types.qualify(spec, idx, "MyApp.Source")) ==
               {:typep_referenced, %{type: {:state, 0}, source: "MyApp.Source"}}
    end

    test "handles nested module names in qualification" do
      src = """
      defmodule Outer.Inner do
        @type t :: integer
        @spec foo() :: t()
      end
      """

      idx = Types.index(body_nodes(src))
      [spec] = specs_in(src)
      rendered = spec |> Types.qualify(idx, "Outer.Inner") |> Sourceror.to_string()

      assert rendered =~ ~r/Outer\.Inner\.t\(\)/
    end

    test "passes through non-spec attributes unchanged" do
      src = """
      defmodule MyApp.Source do
        @doc "hello"
        def f, do: :ok
      end
      """

      [doc_attr] =
        body_nodes(src)
        |> Enum.filter(fn
          {:@, _, [{:doc, _, _}]} -> true
          _ -> false
        end)

      assert Types.qualify(doc_attr, %{{:t, 0} => :public}, "MyApp.Source") == doc_attr
    end
  end
end
