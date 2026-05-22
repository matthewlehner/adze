defmodule AdzeExtractTest do
  use ExUnit.Case, async: false

  alias Adze.Extract

  @tmpdir System.tmp_dir!()

  describe "extract/2 — basic" do
    test "extracts a single def into a new module" do
      source = """
      defmodule MyApp.Source do
        def foo(x), do: x + 1
        def bar(x), do: foo(x) - 1
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "foo/1",
          module: "MyApp.Foo",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_module == "MyApp.Foo"
      assert result.target_content =~ ~r/defmodule MyApp\.Foo do/
      assert result.target_content =~ ~r/def foo\(x\), do: x \+ 1/
      refute result.target_content =~ ~r/def bar/

      # bar/1 still calls foo/1 → alias is inserted in the source
      assert result.new_source =~ ~r/alias MyApp\.Foo/
      refute result.new_source =~ ~r/def foo\(x\)/
      assert result.new_source =~ ~r/def bar\(x\)/

      assert result.source_diff =~ "@@"
      assert {:ok, _} = Code.string_to_quoted(result.target_content)
      assert {:ok, _} = Code.string_to_quoted(result.new_source)
    end

    test "pulls a private closure along with the target" do
      source = """
      defmodule MyApp.Source do
        def public_entry(x), do: helper_a(x) |> helper_b()
        defp helper_a(x), do: x * 2
        defp helper_b(x), do: x + 1

        def unrelated(x), do: x
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "public_entry/1",
          module: "MyApp.Closure",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/def public_entry/
      assert result.target_content =~ ~r/defp helper_a/
      assert result.target_content =~ ~r/defp helper_b/
      refute result.target_content =~ ~r/def unrelated/

      refute result.new_source =~ ~r/defp helper_a/
      refute result.new_source =~ ~r/defp helper_b/
      assert result.new_source =~ ~r/def unrelated/
    end

    test "preserves @spec and @doc on the moved def" do
      source = """
      defmodule MyApp.Source do
        @doc "the foo"
        @spec foo(integer) :: integer
        def foo(x), do: x + 1
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "foo/1",
          module: "MyApp.Foo",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/@doc "the foo"/
      assert result.target_content =~ ~r/@spec foo\(integer\) :: integer/
      assert result.target_content =~ ~r/def foo\(x\)/
    end
  end

  describe "extract/2 — directive filtering" do
    test "alias used inside closure is copied to target" do
      source = """
      defmodule MyApp.Source do
        alias MyApp.Helper
        alias MyApp.Other

        def use_helper(x), do: Helper.shift(x)
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "use_helper/1",
          module: "MyApp.Use",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/alias MyApp\.Helper/
      refute result.target_content =~ ~r/alias MyApp\.Other/
    end

    test "alias with :as binding matches by the as-name" do
      source = """
      defmodule MyApp.Source do
        alias MyApp.SomeLong.Module, as: M
        alias MyApp.Unused, as: U

        def call_m(x), do: M.work(x)
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "call_m/1",
          module: "MyApp.UseM",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/alias MyApp\.SomeLong\.Module, as: M/
      refute result.target_content =~ ~r/Unused/
    end

    test "aliases in target file are grouped without blank-line drift" do
      source = """
      defmodule MyApp.Source do
        alias MyApp.A
        alias MyApp.B
        alias MyApp.C

        def thing, do: A.a() + B.b() + C.c()
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "thing/0",
          module: "MyApp.Thing",
          path: "/tmp/__nonexistent_target__.ex"
        )

      # All three aliases land on consecutive lines (no blank between them).
      assert result.target_content =~
               ~r/alias MyApp\.A\n  alias MyApp\.B\n  alias MyApp\.C/
    end

    test "use/import/require are dropped and surfaced in dropped_directives" do
      # We can't know without macro expansion whether a closure needs
      # `use Foo` / `import Bar` / `require Baz`. The mechanical
      # answer is to drop them and let the compiler tell the AI what
      # was actually needed. Each dropped directive comes back in
      # `dropped_directives` with its kind, source line, and verbatim
      # text so the AI can copy-paste back if the build complains.
      source = """
      defmodule MyApp.Source do
        use MyApp.Magic
        import MyApp.Util
        require Logger

        def thing, do: :ok
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "thing/0",
          module: "MyApp.Thing",
          path: "/tmp/__nonexistent_target__.ex"
        )

      refute result.target_content =~ ~r/use MyApp\.Magic/
      refute result.target_content =~ ~r/import MyApp\.Util/
      refute result.target_content =~ ~r/require Logger/

      kinds = Enum.map(result.dropped_directives, & &1.kind)
      assert :use in kinds
      assert :import in kinds
      assert :require in kinds

      use_entry = Enum.find(result.dropped_directives, &(&1.kind == :use))
      assert use_entry.text == "use MyApp.Magic"
      assert use_entry.line == 2
    end

    test "dropped_directives is empty when source has no use/import/require" do
      source = """
      defmodule MyApp.Source do
        alias MyApp.Helper

        def thing, do: Helper.do_it()
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "thing/0",
          module: "MyApp.Thing",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.dropped_directives == []
    end
  end

  describe "extract/2 — error cases" do
    test "errors when target file already exists" do
      path = Path.join(@tmpdir, "adze_extract_exists_#{System.unique_integer([:positive])}.ex")
      File.write!(path, "defmodule X do\nend\n")
      on_exit(fn -> File.rm(path) end)

      source = "defmodule S do\n  def f, do: :ok\nend\n"

      assert {:error, {:target_exists, ^path}} =
               Extract.extract(source, definition: "f/0", module: "X", path: path)
    end

    test "errors on bad module name" do
      source = "defmodule S do\n  def f, do: :ok\nend\n"

      assert {:error, {:bad_module_name, "lowercase.mod"}} =
               Extract.extract(source,
                 definition: "f/0",
                 module: "lowercase.mod",
                 path: "/tmp/__nope__.ex"
               )
    end

    test "errors when the definition isn't found" do
      source = "defmodule S do\n  def f, do: :ok\nend\n"

      assert {:error, {:not_found, {:missing, 0}}} =
               Extract.extract(source,
                 definition: "missing/0",
                 module: "X",
                 path: "/tmp/__nope__.ex"
               )
    end

    test "errors when the definition exists in multiple modules without --from-module" do
      source = """
      defmodule A do
        def shared, do: :a
      end

      defmodule B do
        def shared, do: :b
      end
      """

      assert {:error, {:ambiguous_source_module, info}} =
               Extract.extract(source,
                 definition: "shared/0",
                 module: "X",
                 path: "/tmp/__nope__.ex"
               )

      assert info.definition == {:shared, 0}
      assert MapSet.new(info.modules) == MapSet.new(["A", "B"])
    end

    test "--from-module disambiguates multi-module files" do
      source = """
      defmodule A do
        def shared, do: :a
        def consumer, do: shared()
      end

      defmodule B do
        def shared, do: :b
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "shared/0",
          module: "C",
          from_module: "A",
          path: "/tmp/__nope__.ex"
        )

      assert result.target_content =~ ~r/def shared, do: :a/
      refute result.target_content =~ ~r/:b/
      # The source side: A gets the alias (consumer/0 still calls it) and
      # has shared removed; B is untouched.
      assert result.new_source =~ ~r/defmodule A do.*alias C/s
      assert result.new_source =~ ~r/defmodule B do\s*\n\s*def shared, do: :b/
    end

    test "--from-module that doesn't contain the def errors" do
      source = """
      defmodule A do
        def shared, do: :a
      end

      defmodule B do
        def other, do: :b
      end
      """

      assert {:error, {:from_module_mismatch, info}} =
               Extract.extract(source,
                 definition: "shared/0",
                 module: "C",
                 from_module: "B",
                 path: "/tmp/__nope__.ex"
               )

      assert info.from == "B"
      assert info.candidates == ["A"]
    end

    test "missing --definition opt" do
      assert {:error, {:missing_opt, :definition}} =
               Extract.extract("defmodule X do\nend\n", module: "Y", path: "/tmp/__nope__.ex")
    end

    test "missing --module opt" do
      assert {:error, {:missing_opt, :module}} =
               Extract.extract("defmodule X do\nend\n", definition: "foo/0")
    end
  end

  describe "extract/2 — target path derivation" do
    test "derives lib/my_app/foo.ex from MyApp.Foo (with mix_root)" do
      source = "defmodule S do\n  def f, do: :ok\nend\n"

      tmp = Path.join(@tmpdir, "adze_extract_root_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, result} =
        Extract.extract(source,
          definition: "f/0",
          module: "MyApp.Foo",
          mix_root: tmp
        )

      assert result.target_path == Path.join(tmp, "lib/my_app/foo.ex")
    end
  end

  describe "extract/2 — alias insertion in source" do
    test "skips alias when no internal caller exists for the target def" do
      source = """
      defmodule MyApp.Source do
        @moduledoc false

        def public_api(x), do: helper(x)
        defp helper(x), do: x + 1
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "public_api/1",
          module: "MyApp.Api",
          path: "/tmp/__nonexistent_target__.ex"
        )

      refute result.new_source =~ ~r/alias MyApp\.Api/
    end

    test "inserts alias when a remaining def in the source calls the target" do
      source = """
      defmodule MyApp.Source do
        def shared(x), do: x * 2
        def caller(x), do: shared(x) + 1
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "shared/1",
          module: "MyApp.Shared",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.new_source =~ ~r/alias MyApp\.Shared/
    end

    test "alias lands after @moduledoc, not between defmodule and @moduledoc" do
      source = """
      defmodule MyApp.Source do
        @moduledoc "the source"

        def shared(x), do: x
        def caller(x), do: shared(x)
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "shared/1",
          module: "MyApp.Shared",
          path: "/tmp/__nonexistent_target__.ex"
        )

      # @moduledoc precedes the alias
      assert result.new_source =~ ~r/@moduledoc "the source".*alias MyApp\.Shared/s
      refute result.new_source =~ ~r/alias MyApp\.Shared.*@moduledoc/s
    end

    test "alias lands after the last existing alias when one exists" do
      source = """
      defmodule MyApp.Source do
        alias MyApp.Existing
        alias MyApp.AlsoExisting

        def shared(x), do: x
        def caller(x), do: shared(x) + Existing.bump() + AlsoExisting.bump()
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "shared/1",
          module: "MyApp.Shared",
          path: "/tmp/__nonexistent_target__.ex"
        )

      # both existing aliases come before the new one
      assert result.new_source =~
               ~r/alias MyApp\.Existing.*alias MyApp\.AlsoExisting.*alias MyApp\.Shared/s
    end
  end

  describe "extract/2 — caller call-site rewriting" do
    # Compile a string defmodule and return the bytecode-mod pairs.
    # Cleans up afterward so tests don't pollute each other.
    defp compile_and_cleanup(sources) when is_list(sources) do
      mods =
        Enum.flat_map(sources, fn src ->
          src |> Code.compile_string() |> Enum.map(&elem(&1, 0))
        end)

      on_exit(fn ->
        for m <- mods do
          :code.purge(m)
          :code.delete(m)
        end
      end)

      mods
    end

    test "rewrites bare call sites in surviving callers and compiles" do
      source = """
      defmodule HasCaller do
        @moduledoc false

        def caller(x), do: target(x) + 1
        def target(x), do: helper(x) * 2
        defp helper(x), do: x + 100
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "target/1",
          module: "HasCaller.Target",
          path: "/tmp/__nonexistent__.ex"
        )

      assert result.new_source =~ ~r/Target\.target\(x\) \+ 1/
      # bare local call (not preceded by `.`) must not remain
      refute result.new_source =~ ~r/(?<![.\w])target\(x\) \+ 1/

      # Compile target first (defines the module), then source (references it).
      mods = compile_and_cleanup([result.target_content, result.new_source])
      assert HasCaller.Target in mods
      assert HasCaller in mods
    end

    test "rewrites captures &target/1 → &Target.target/1" do
      source = """
      defmodule WithCaptures do
        def map(xs), do: Enum.map(xs, &target/1)
        def target(x), do: x * 2
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "target/1",
          module: "WithCaptures.Target",
          path: "/tmp/__nonexistent__.ex"
        )

      assert result.new_source =~ ~r/&Target\.target\/1/
      refute result.new_source =~ ~r/&target\/1/

      mods = compile_and_cleanup([result.target_content, result.new_source])
      assert WithCaptures.Target in mods
      assert WithCaptures in mods
    end

    test "rewrites pipelines (x |> target() → x |> Target.target())" do
      source = """
      defmodule Piped do
        def thing(x), do: x |> target() |> Kernel.+(1)
        def target(x), do: x * 2
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "target/1",
          module: "Piped.Target",
          path: "/tmp/__nonexistent__.ex"
        )

      assert result.new_source =~ ~r/Target\.target\(\)/
      mods = compile_and_cleanup([result.target_content, result.new_source])
      assert Piped.Target in mods
      assert Piped in mods
    end

    test "rewrites multiple call sites in the same caller" do
      source = """
      defmodule MultiCall do
        def caller(x, y), do: target(x) + target(y) + target(x + y)
        def target(x), do: x * 2
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "target/1",
          module: "MultiCall.Target",
          path: "/tmp/__nonexistent__.ex"
        )

      # All three call sites must be rewritten.
      assert Regex.scan(~r/Target\.target\(/, result.new_source) |> length() == 3
      mods = compile_and_cleanup([result.target_content, result.new_source])
      assert MultiCall.Target in mods
      assert MultiCall in mods
    end

    test "does not rewrite the def head name when arities differ" do
      # `target/2` extracted; surviving `target/0` and `target/1` are
      # different defs at different arities. Their HEADS should NOT be
      # rewritten (they're definitions, not calls).
      source = """
      defmodule ArityCollide do
        def target, do: :zero
        def target(x), do: x
        def target(x, y), do: x + y
        def consumer(a, b), do: target(a, b) + target(a)
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "target/2",
          module: "ArityCollide.Target",
          path: "/tmp/__nonexistent__.ex"
        )

      # target/0 and target/1 still live in the source, unchanged in their heads.
      assert result.new_source =~ ~r/def target, do: :zero/
      assert result.new_source =~ ~r/def target\(x\), do: x/
      # target/2 call rewritten; target/1 call left bare (target/1 still local).
      assert result.new_source =~ ~r/Target\.target\(a, b\) \+ target\(a\)/
    end

    test "does not rewrite when there's no internal caller — no alias inserted" do
      # Public-API extraction. The closure of public_api/1 is just itself
      # (helper is private and only called by public_api). No surviving
      # def references public_api, so nothing to rewrite and no alias.
      source = """
      defmodule NoCallers do
        def public_api(x), do: helper(x)
        defp helper(x), do: x
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "public_api/1",
          module: "NoCallers.Api",
          path: "/tmp/__nonexistent__.ex"
        )

      refute result.new_source =~ ~r/alias NoCallers\.Api/
      refute result.new_source =~ ~r/public_api/
    end

    test "does not rewrite arity-0 bare calls without parens (intentional limitation)" do
      # `target` (no parens) is ambiguous with a variable reference;
      # adze conservatively leaves it alone. Adding parens (`target()`)
      # would get the rewrite.
      source = """
      defmodule NoParens do
        def consumer, do: target() + 1
        def target, do: 42
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "target/0",
          module: "NoParens.Target",
          path: "/tmp/__nonexistent__.ex"
        )

      # `target()` (with parens) is unambiguous → rewritten.
      assert result.new_source =~ ~r/Target\.target\(\)/
    end
  end

  describe "extract/2 — formatter_opts (.formatter.exs / import_deps)" do
    # Without the project's formatter opts, `Code.format_string!`
    # parenthesizes every macro call site whose name isn't in its
    # built-in `locals_without_parens` — turning Ecto's
    # `field :foo, :string` into `field(:foo, :string)`, the same for
    # `belongs_to`, `from`, Phoenix routes, Absinthe field, etc.

    test "honors locals_without_parens in the rewritten source" do
      source = """
      defmodule MyApp.Source do
        def alpha, do: 1

        def unrelated do
          my_dsl :a
          my_dsl :b
        end
      end
      """

      {:ok, with_opts} =
        Extract.extract(source,
          definition: "alpha/0",
          module: "MyApp.Alpha",
          path: "/tmp/__nonexistent_target__.ex",
          formatter_opts: [locals_without_parens: [my_dsl: 1]]
        )

      assert with_opts.new_source =~ "my_dsl :a"
      assert with_opts.new_source =~ "my_dsl :b"
      refute with_opts.new_source =~ "my_dsl(:a)"
    end

    test "without formatter_opts, the same source is parenthesized (regression baseline)" do
      # Documents what happens absent the fix — locks in the contract
      # that `formatter_opts: []` opts into the formatter's defaults.
      source = """
      defmodule MyApp.Source do
        def alpha, do: 1

        def unrelated, do: my_dsl :a
      end
      """

      {:ok, without_opts} =
        Extract.extract(source,
          definition: "alpha/0",
          module: "MyApp.Alpha",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert without_opts.new_source =~ "my_dsl(:a)"
    end

    test "honors locals_without_parens in the extracted target file" do
      source = """
      defmodule MyApp.Source do
        def alpha do
          my_dsl :a
          my_dsl :b
        end
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "alpha/0",
          module: "MyApp.Alpha",
          path: "/tmp/__nonexistent_target__.ex",
          formatter_opts: [locals_without_parens: [my_dsl: 1]]
        )

      assert result.target_content =~ "my_dsl :a"
      refute result.target_content =~ "my_dsl(:a)"
    end
  end

  describe "extract/2 — __MODULE__ rewriting in def bodies" do
    # __MODULE__ inside a def body resolves to the enclosing module at
    # compile time. After extraction the enclosing module is the new
    # *target*, so %__MODULE__{} would try to match the target's struct
    # (which doesn't exist) and other __MODULE__ refs would resolve to
    # the wrong module. Adze rewrites them to the source module's
    # aliased form during AST rendering.

    test "rewrites %__MODULE__{} struct match to the source module" do
      source = ~S"""
      defmodule MyApp.Source do
        defstruct [:id, :name]

        def label(%__MODULE__{name: name}), do: "<#{name}>"
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "label/1",
          module: "MyApp.Label",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/%MyApp\.Source\{/
      refute result.target_content =~ ~r/%__MODULE__\{/
      assert {:ok, _} = Code.string_to_quoted(result.target_content)
    end

    test "rewrites bare __MODULE__ references in the body" do
      source = """
      defmodule MyApp.Source do
        def kind, do: __MODULE__
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "kind/0",
          module: "MyApp.Kind",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/do: MyApp\.Source/
      refute result.target_content =~ ~r/__MODULE__/
      assert {:ok, _} = Code.string_to_quoted(result.target_content)
    end

    test "does not force AST rendering when the def has no __MODULE__ ref" do
      # Without __MODULE__ (or local type specs), the slice-from-source
      # path stays in effect — verbatim including comments.
      source = """
      defmodule MyApp.Source do
        # hand-tuned comment that the slice path preserves verbatim
        def plain(x), do: x + 1
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "plain/1",
          module: "MyApp.Plain",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/hand-tuned comment/
    end
  end

  describe "extract/2 — source-module-local call qualification" do
    # An extracted def called a bare local `fetch_record(id)` whose
    # definition was NOT in the closure (it stayed in the source
    # module). The target file emitted the call verbatim — leaving an
    # undefined function in the new module. Extract now qualifies bare
    # calls to source-staying functions as `SourceModule.fn(...)`.

    test "rewrites bare call to a source-staying function" do
      source = ~S"""
      defmodule MyApp.Source do
        def fetch(id), do: {:ok, id}

        def update(id, attrs) do
          with {:ok, item} <- fetch(id) do
            apply_changes(item, attrs)
          end
        end

        defp apply_changes(item, attrs), do: Map.merge(item, attrs)
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "update/2",
          module: "MyApp.Updater",
          path: "/tmp/__nonexistent_target__.ex"
        )

      # The extracted def's body should qualify `fetch(id)` to the
      # full source-module path. `apply_changes/2` is in the closure
      # (private, called only by update/2) and stays bare.
      assert result.target_content =~ ~r/MyApp\.Source\.fetch\(id\)/
      refute result.target_content =~ ~r/<-\s+fetch\(id\)/
      assert result.target_content =~ ~r/apply_changes\(item, attrs\)/
      assert {:ok, _} = Code.string_to_quoted(result.target_content)
    end

    test "rewrites pipe to a source-staying function" do
      source = """
      defmodule MyApp.Source do
        def normalize(x), do: x |> String.trim()

        def go(input) do
          input |> normalize() |> String.upcase()
        end
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "go/1",
          module: "MyApp.Go",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/MyApp\.Source\.normalize/
      assert {:ok, _} = Code.string_to_quoted(result.target_content)
    end

    test "rewrites capture of a source-staying function" do
      source = """
      defmodule MyApp.Source do
        def double(x), do: x * 2

        def go(xs), do: Enum.map(xs, &double/1)
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "go/1",
          module: "MyApp.Go",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/&MyApp\.Source\.double\/1/
      refute result.target_content =~ ~r/&double\/1/
      assert {:ok, _} = Code.string_to_quoted(result.target_content)
    end

    test "calls to OTHER closure members stay bare" do
      # apply_changes is private and only called by update/2, so it's
      # pulled into the closure. The call from update/2 → apply_changes
      # must stay bare so both work after extraction.
      source = ~S"""
      defmodule MyApp.Source do
        def update(item, attrs) do
          apply_changes(item, attrs)
        end

        defp apply_changes(item, attrs), do: Map.merge(item, attrs)
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "update/2",
          module: "MyApp.Updater",
          path: "/tmp/__nonexistent_target__.ex"
        )

      # No qualification — bare call to closure member.
      assert result.target_content =~ ~r/apply_changes\(item, attrs\)/
      refute result.target_content =~ ~r/MyApp\.Source\.apply_changes/
      assert {:ok, _} = Code.string_to_quoted(result.target_content)
    end

    test "does not touch the def's own head signature" do
      # The def head `update(id, attrs)` would syntactically match the
      # `{name, _, args}` pattern in the walker. The walker must skip
      # the head and only rewrite inside the body.
      source = ~S"""
      defmodule MyApp.Source do
        def update(id), do: {:ok, id}

        def perform(id) do
          update(id)
        end
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "perform/1",
          module: "MyApp.Performer",
          path: "/tmp/__nonexistent_target__.ex"
        )

      # The body call rewrites to qualified, but the def head stays
      # `def perform(id)` (not `def MyApp.Source.perform(id)`).
      assert result.target_content =~ ~r/def perform\(id\)/
      assert result.target_content =~ ~r/MyApp\.Source\.update\(id\)/
      assert {:ok, _} = Code.string_to_quoted(result.target_content)
    end

    test "slice-from-source preserves comments when no qualification needed" do
      # Regression guard: introducing the new AST-rendering trigger
      # must not break the verbatim-slice path for defs that don't
      # actually call source-staying functions.
      source = """
      defmodule MyApp.Source do
        # this comment should survive verbatim
        def standalone(x), do: x + 1
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "standalone/1",
          module: "MyApp.Standalone",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ "should survive verbatim"
    end
  end

  describe "extract/2 — local type qualification" do
    test "qualifies bare local type calls in extracted @spec" do
      source = """
      defmodule MyApp.Source do
        @type t :: %{id: integer}

        @spec wrap(integer) :: t()
        def wrap(id), do: %{id: id}
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "wrap/1",
          module: "MyApp.Wrap",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/MyApp\.Source\.t\(\)/
      refute result.target_content =~ ~r/@type t :: /
      assert {:ok, _} = Code.string_to_quoted(result.target_content)
    end

    test "leaves already-qualified type calls intact" do
      source = """
      defmodule MyApp.Source do
        @type t :: %{}

        @spec wrap(String.t(), [MyApp.Other.id()]) :: {:ok, t()} | :error
        def wrap(_, _), do: :error
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "wrap/2",
          module: "MyApp.Wrap",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/MyApp\.Source\.t\(\)/
      assert result.target_content =~ ~r/String\.t\(\)/
      assert result.target_content =~ ~r/MyApp\.Other\.id\(\)/
      refute result.target_content =~ ~r/MyApp\.Source\.String/
      refute result.target_content =~ ~r/MyApp\.Source\.MyApp\.Other/
    end

    test "leaves built-in types alone" do
      source = """
      defmodule MyApp.Source do
        @type t :: integer

        @spec add(integer, integer) :: pos_integer | t()
        def add(a, b), do: a + b
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "add/2",
          module: "MyApp.Add",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/MyApp\.Source\.t\(\)/
      refute result.target_content =~ ~r/MyApp\.Source\.integer/
      refute result.target_content =~ ~r/MyApp\.Source\.pos_integer/
    end

    test "errors on @typep references in extracted @spec" do
      source = """
      defmodule MyApp.Source do
        @typep state :: :idle | :running

        @spec snapshot() :: state()
        def snapshot, do: :idle
      end
      """

      assert {:error, {:typep_referenced, %{type: {:state, 0}, source: "MyApp.Source"}}} =
               Extract.extract(source,
                 definition: "snapshot/0",
                 module: "MyApp.Snap",
                 path: "/tmp/__nonexistent_target__.ex"
               )
    end

    test "does not rewrite the @spec head function name" do
      # Edge: function name `wrap` happens to also be a local type name.
      # The function-head name is preserved; the type call gets qualified.
      source = """
      defmodule MyApp.Source do
        @type wrap :: integer

        @spec wrap(wrap()) :: wrap()
        def wrap(x), do: x
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "wrap/1",
          module: "MyApp.Wrap",
          path: "/tmp/__nonexistent_target__.ex"
        )

      # function name unchanged in both spec head and clause head
      assert result.target_content =~
               ~r/@spec wrap\(MyApp\.Source\.wrap\(\)\) :: MyApp\.Source\.wrap\(\)/

      assert result.target_content =~ ~r/def wrap\(x\)/
      refute result.target_content =~ ~r/def MyApp\.Source\.wrap/
    end

    test "qualifies recursively into parameterized types" do
      source = """
      defmodule MyApp.Source do
        @type id :: pos_integer
        @type wrap(a) :: {:ok, a}

        @spec build() :: wrap(id())
        def build, do: {:ok, 1}
      end
      """

      {:ok, result} =
        Extract.extract(source,
          definition: "build/0",
          module: "MyApp.Build",
          path: "/tmp/__nonexistent_target__.ex"
        )

      assert result.target_content =~ ~r/MyApp\.Source\.wrap\(MyApp\.Source\.id\(\)\)/
    end
  end

  describe "extract!/2" do
    setup do
      dir = Path.join(@tmpdir, "adze_extract_dir_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      lib_dir = Path.join(dir, "lib")
      File.mkdir_p!(lib_dir)

      source_path = Path.join(lib_dir, "source.ex")

      File.write!(source_path, """
      defmodule TmpExtract.Source do
        def public_entry(x), do: helper(x)
        defp helper(x), do: x + 1

        def remaining_caller(x), do: public_entry(x)
      end
      """)

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir, source_path: source_path}
    end

    test "extract_file returns the result without writing", %{source_path: path, dir: dir} do
      original = File.read!(path)

      {:ok, result} =
        Extract.extract_file(path,
          definition: "public_entry/1",
          module: "TmpExtract.Out",
          mix_root: dir
        )

      assert File.read!(path) == original
      refute File.exists?(result.target_path)
    end

    test "extract! writes both target and modified source", %{source_path: path, dir: dir} do
      {:ok, result} =
        Extract.extract!(path,
          definition: "public_entry/1",
          module: "TmpExtract.Out",
          mix_root: dir
        )

      assert File.exists?(result.target_path)
      assert File.read!(result.target_path) =~ ~r/def public_entry/
      assert File.read!(result.target_path) =~ ~r/defp helper/

      modified = File.read!(path)
      refute modified =~ ~r/def public_entry/
      refute modified =~ ~r/defp helper/
      assert modified =~ ~r/alias TmpExtract\.Out/
    end
  end

  describe "extract_file/2 — cross-file caller rewriting (Session 6.5)" do
    # Project-wide caller fix-up: when extract moves a def out of
    # SourceModule into TargetModule, every other file that calls
    # SourceModule.target(...) (and pipe / capture variants) needs to
    # be rewritten to TargetModule.target(...). Driven by
    # Adze.ProjectRewrite + Igniter.Refactors.Rename.rename_function/4.

    test "rewrites SourceModule.target/n call sites in callers" do
      files = %{
        "lib/source.ex" => """
        defmodule MyApp.Source do
          def public_entry(x), do: x + 1
          def other(x), do: x * 2
        end
        """,
        "lib/caller.ex" => """
        defmodule MyApp.Caller do
          def go(x), do: MyApp.Source.public_entry(x)
        end
        """
      }

      {:ok, result} =
        Extract.extract_file("lib/source.ex",
          definition: "public_entry/1",
          module: "MyApp.PublicEntry",
          files: files
        )

      caller_diff = result.caller_diffs["lib/caller.ex"]
      assert caller_diff, "expected caller file to be touched"
      assert caller_diff =~ "MyApp.PublicEntry"
    end

    test "rewrites &SourceModule.target/n captures in callers" do
      files = %{
        "lib/source.ex" => """
        defmodule MyApp.Source do
          def shout(s), do: String.upcase(s)
        end
        """,
        "lib/caller.ex" => """
        defmodule MyApp.Caller do
          def all(xs), do: Enum.map(xs, &MyApp.Source.shout/1)
        end
        """
      }

      {:ok, result} =
        Extract.extract_file("lib/source.ex",
          definition: "shout/1",
          module: "MyApp.Shout",
          files: files
        )

      caller_diff = result.caller_diffs["lib/caller.ex"]
      assert caller_diff, "expected caller file to be touched"
      assert caller_diff =~ "MyApp.Shout"
    end

    test "rewrites pipe call sites in callers" do
      files = %{
        "lib/source.ex" => """
        defmodule MyApp.Source do
          def shout(s), do: String.upcase(s)
        end
        """,
        "lib/caller.ex" => """
        defmodule MyApp.Caller do
          def go(x), do: x |> MyApp.Source.shout()
        end
        """
      }

      {:ok, result} =
        Extract.extract_file("lib/source.ex",
          definition: "shout/1",
          module: "MyApp.Shout",
          files: files
        )

      caller_diff = result.caller_diffs["lib/caller.ex"]
      assert caller_diff, "expected caller file to be touched"
      assert caller_diff =~ "MyApp.Shout"
    end

    test "no caller_diffs when there are no external callers" do
      files = %{
        "lib/source.ex" => """
        defmodule MyApp.Source do
          def hello, do: :world
        end
        """,
        "lib/unrelated.ex" => """
        defmodule MyApp.Unrelated do
          def go, do: :ok
        end
        """
      }

      {:ok, result} =
        Extract.extract_file("lib/source.ex",
          definition: "hello/0",
          module: "MyApp.Hello",
          files: files
        )

      assert result.caller_diffs == %{}
    end

    test "extract_file is a dry-run — does not modify the in-memory project" do
      # Since `files:` mode is in-memory, the assertion is that the
      # caller diff is produced but write!/1 isn't reachable (test mode
      # refuses to write). The dry-run nature is verified by the fact
      # that no exception is raised and the result is returned with
      # caller_diffs populated.
      files = %{
        "lib/source.ex" => """
        defmodule MyApp.Source do
          def hello, do: :world
        end
        """,
        "lib/caller.ex" => """
        defmodule MyApp.Caller do
          def go, do: MyApp.Source.hello()
        end
        """
      }

      {:ok, result} =
        Extract.extract_file("lib/source.ex",
          definition: "hello/0",
          module: "MyApp.Hello",
          files: files
        )

      assert Map.has_key?(result.caller_diffs, "lib/caller.ex")
    end
  end

  describe "extract!/2 — cross-file caller rewriting on disk" do
    @describetag :tmp_dir

    setup do
      dir = Path.join(@tmpdir, "adze_extract_xfile_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "lib"))

      source_path = Path.join(dir, "lib/source.ex")
      caller_path = Path.join(dir, "lib/caller.ex")

      File.write!(source_path, """
      defmodule XFile.Source do
        def shout(s), do: String.upcase(s)
      end
      """)

      File.write!(caller_path, """
      defmodule XFile.Caller do
        def go(s), do: XFile.Source.shout(s)
      end
      """)

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir, source_path: source_path, caller_path: caller_path}
    end

    test "extract! rewrites caller files on disk", %{
      dir: dir,
      source_path: source_path,
      caller_path: caller_path
    } do
      {:ok, result} =
        Extract.extract!(source_path,
          definition: "shout/1",
          module: "XFile.Shout",
          mix_root: dir
        )

      # The new target module file exists.
      assert File.exists?(result.target_path)

      # The caller has been rewritten in place: XFile.Source.shout →
      # XFile.Shout.shout.
      caller_after = File.read!(caller_path)
      refute caller_after =~ ~r/XFile\.Source\.shout/
      assert caller_after =~ ~r/XFile\.Shout\.shout/
    end
  end
end
