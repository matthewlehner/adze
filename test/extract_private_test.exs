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

    test "external caller in a sibling module is not hidden by a later alias with the same name" do
      source = """
      defmodule MyApp.Foo do
        def helper, do: :ok
      end
      """

      caller = """
      defmodule First do
        alias MyApp.Foo, as: Target
        def go, do: Target.helper()
      end

      defmodule Second do
        alias MyApp.Other, as: Target
        def go, do: Target.helper()
      end
      """

      assert {:error, {:external_callers, [ref]}} =
               ExtractPrivate.extract_private(source,
                 definition: "helper/0",
                 path: "lib/foo.ex",
                 files: %{"lib/foo.ex" => source, "lib/caller.ex" => caller}
               )

      assert ref.path == "lib/caller.ex"
      assert ref.in_module == "First"
    end

    test "external calls to a default-argument arity block the flip" do
      source = ~S"""
      defmodule MyApp.Foo do
        def helper(a, b \\ 1), do: {a, b}
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def go, do: MyApp.Foo.helper(:value)
      end
      """

      assert {:error, {:external_callers, [ref]}} =
               ExtractPrivate.extract_private(source,
                 definition: "helper/2",
                 path: "lib/foo.ex",
                 files: %{"lib/foo.ex" => source, "lib/caller.ex" => caller}
               )

      assert ref.arity == 1
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

    test "a caller isn't hidden by a function-local alias in an earlier def" do
      source = """
      defmodule Helper do
        def run, do: :ok
      end
      """

      caller = """
      defmodule MyApp.Caller do
        def one do
          alias MyApp.Other.Helper
          Helper.run()
        end

        def two, do: Helper.run()
      end
      """

      assert {:error, {:external_callers, [ref]}} =
               ExtractPrivate.extract_private(source,
                 definition: "run/0",
                 path: "lib/helper.ex",
                 files: %{"lib/helper.ex" => source, "lib/caller.ex" => caller}
               )

      assert ref.line == 7
    end

    test "a caller via a nested module's implicit alias blocks the flip" do
      source = """
      defmodule Outer do
        defmodule Inner do
          def f, do: :ok
        end

        def go, do: Inner.f()
      end
      """

      assert {:error, {:external_callers, [ref]}} =
               ExtractPrivate.extract_private(source,
                 definition: "f/0",
                 from_module: "Outer.Inner",
                 path: "lib/outer.ex",
                 files: %{"lib/outer.ex" => source}
               )

      assert ref.in_module == "Outer"
    end

    test "qualified self-calls inside the module block the flip" do
      source = """
      defmodule MyApp.Foo do
        alias __MODULE__, as: Me

        def a(x), do: MyApp.Foo.helper(x)
        def b(x), do: __MODULE__.helper(x)
        def c, do: &__MODULE__.helper/1
        def d(x), do: x |> __MODULE__.helper()
        def e(x), do: Me.helper(x)
        def f(x), do: helper(x)
        def helper(x), do: x * 2
      end
      """

      assert {:error, {:external_callers, refs}} =
               ExtractPrivate.extract_private(source,
                 definition: "helper/1",
                 path: "lib/foo.ex",
                 files: %{"lib/foo.ex" => source}
               )

      assert Enum.map(refs, & &1.line) == [4, 5, 6, 7, 8]
      assert Enum.all?(refs, &(&1.in_module == "MyApp.Foo"))
      assert Enum.map(refs, & &1.kind) == [:call, :call, :capture, :call, :call]
    end

    test "malformed definition specs return errors rather than raising" do
      source = "defmodule X do\n  def real, do: :ok\nend\n"

      for spec <- ["real", "real/nope"] do
        assert {:error, {:bad_definition_spec, ^spec}} =
                 ExtractPrivate.extract_private(source,
                   definition: spec,
                   path: "lib/x.ex",
                   files: %{"lib/x.ex" => source}
                 )
      end
    end

    test "modules find-callers can't search are refused, not reported as caller-free" do
      for {source, module} <- [
            {"defmodule :my_erl_mod do\n  def helper, do: :ok\nend\n", ":my_erl_mod"},
            {"defmodule Module.concat([:a]) do\n  def helper, do: :ok\nend\n",
             "Module.concat([:a])"}
          ] do
        assert {:error, {:unsupported_module, ^module}} =
                 ExtractPrivate.extract_private(source,
                   definition: "helper/0",
                   path: "lib/m.ex",
                   files: %{"lib/m.ex" => source}
                 )
      end
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

  describe "extract_private/2 — behaviour callbacks" do
    defp ep(source, definition, extra \\ []) do
      ExtractPrivate.extract_private(
        source,
        [definition: definition, path: "lib/cb.ex", files: %{"lib/cb.ex" => source}] ++ extra
      )
    end

    test "@impl true is refused, even with force" do
      source = """
      defmodule MyApp.Worker do
        @behaviour GenServer

        @impl true
        def init(arg), do: {:ok, arg}
      end
      """

      for extra <- [[], [force: true]] do
        assert {:error,
                {:behaviour_callback,
                 %{definition: {:init, 1}, module: "MyApp.Worker", reason: {:impl, "true"}}}} =
                 ep(source, "init/1", extra)
      end
    end

    test "@impl SomeBehaviour is refused" do
      source = """
      defmodule MyApp.Worker do
        @impl GenServer
        def init(arg), do: {:ok, arg}
      end
      """

      assert {:error, {:behaviour_callback, %{reason: {:impl, "GenServer"}}}} =
               ep(source, "init/1")
    end

    test "a callback of a loadable @behaviour is refused without @impl" do
      source = """
      defmodule MyApp.Worker do
        @behaviour GenServer
        def init(arg), do: {:ok, arg}
        def helper(x), do: x
      end
      """

      assert {:error, {:behaviour_callback, %{reason: {:behaviour, "GenServer"}}}} =
               ep(source, "init/1", force: true)

      # A non-callback in a module whose behaviours are all resolvable
      # is fine without --force.
      assert {:ok, %{to_kind: :defp}} = ep(source, "helper/1")
    end

    test "a callback of a `use`d behaviour is refused" do
      source = """
      defmodule MyApp.Worker do
        use GenServer
        def handle_call(msg, _from, state), do: {:reply, msg, state}
      end
      """

      assert {:error, {:behaviour_callback, %{reason: {:behaviour, "GenServer"}}}} =
               ep(source, "handle_call/3", force: true)
    end

    test "a non-callback in a module that only `use`s loadable behaviours is allowed" do
      source = """
      defmodule MyApp.Worker do
        use GenServer
        def init(arg), do: {:ok, helper(arg)}
        def helper(x), do: x
      end
      """

      assert {:ok, %{to_kind: :defp}} = ep(source, "helper/1")
    end

    test "a module with `use` is refused as a possible callback unless forced" do
      # Phoenix-style: actions are dispatched dynamically and `use`
      # doesn't name a behaviour we can check.
      source = """
      defmodule MyAppWeb.PageController do
        use MyAppWeb, :controller
        def index(conn, _params), do: conn
      end
      """

      assert {:error,
              {:possible_callback,
               %{
                 definition: {:index, 2},
                 module: "MyAppWeb.PageController",
                 uses: ["MyAppWeb"],
                 behaviours: []
               }}} = ep(source, "index/2")

      assert {:ok, %{to_kind: :defp}} = ep(source, "index/2", force: true)
    end

    test "an unloadable @behaviour is refused as a possible callback unless forced" do
      source = """
      defmodule MyApp.Impl do
        @behaviour MyApp.NotCompiledBehaviour
        def run(x), do: x
      end
      """

      assert {:error,
              {:possible_callback, %{uses: [], behaviours: ["MyApp.NotCompiledBehaviour"]}}} =
               ep(source, "run/1")

      assert {:ok, _} = ep(source, "run/1", force: true)
    end

    test "@impl false doesn't count as a callback" do
      source = """
      defmodule MyApp.Plain do
        @impl false
        def helper(x), do: x
      end
      """

      assert {:ok, %{to_kind: :defp}} = ep(source, "helper/1")
    end

    test "use / @behaviour in a sibling or nested module doesn't affect this module" do
      source = """
      defmodule MyApp.Outer do
        def helper(x), do: x

        defmodule Inner do
          use GenServer
          def init(a), do: {:ok, a}
        end
      end
      """

      assert {:ok, %{to_kind: :defp}} = ep(source, "helper/1", from_module: "MyApp.Outer")
    end

    test "macro callbacks are recognised" do
      source = """
      defmodule MyApp.Mac do
        @behaviour MyApp.Mac.Beh
        defmacro gen(x), do: x
      end
      """

      Code.compile_string("""
      defmodule MyApp.Mac.Beh do
        @macrocallback gen(term) :: Macro.t()
      end
      """)

      on_exit(fn ->
        :code.purge(MyApp.Mac.Beh)
        :code.delete(MyApp.Mac.Beh)
      end)

      assert {:error, {:behaviour_callback, %{reason: {:behaviour, "MyApp.Mac.Beh"}}}} =
               ep(source, "gen/1", force: true)
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
