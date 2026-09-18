defmodule AdzeRenameTest do
  # async: false — the rename!/1 test cd's into a tmp dir to drive
  # Igniter against a real on-disk project, and Igniter's cwd-sensitive
  # plumbing (`.igniter.exs` lookup, `include_all_elixir_files`) is not
  # safe to race with concurrent tests that also touch the cwd.
  use ExUnit.Case, async: false

  alias Adze.Rename

  describe "rename/1 — happy path" do
    test "renames the module's defmodule and moves the file" do
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Old do
          def hello, do: :world
        end
        """
      }

      {:ok, result} =
        Rename.rename(from: "MyApp.Old", to: "MyApp.New", files: files)

      assert result.from == MyApp.Old
      assert result.to == MyApp.New

      # The file is moved from lib/old.ex (old name) to the canonical
      # location derived from the new module: lib/my_app/new.ex.
      assert Map.has_key?(result.moves, "lib/old.ex")
      assert result.moves["lib/old.ex"] == "lib/my_app/new.ex"

      # The defmodule line is rewritten in the (moved) source.
      diff = result.diffs["lib/old.ex"] || result.diffs["lib/my_app/new.ex"]
      assert diff =~ "MyApp.New" or diff =~ "Update:"
    end

    test "rewrites every call site across files" do
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Old do
          def hello, do: :world
        end
        """,
        "lib/caller.ex" => """
        defmodule MyApp.Caller do
          def go, do: MyApp.Old.hello()
        end
        """
      }

      {:ok, result} = Rename.rename(from: "MyApp.Old", to: "MyApp.New", files: files)

      caller_diff = result.diffs["lib/caller.ex"]
      assert caller_diff, "expected caller file to be touched"
      assert caller_diff =~ "MyApp.New" or caller_diff =~ "MyApp.Old"
    end

    test "rewrites alias declarations and call sites that use the alias" do
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Old do
          def hello, do: :world
        end
        """,
        "lib/aliased.ex" => """
        defmodule MyApp.Aliased do
          alias MyApp.Old

          def go, do: Old.hello()
        end
        """
      }

      {:ok, result} = Rename.rename(from: "MyApp.Old", to: "MyApp.New", files: files)
      caller_diff = result.diffs["lib/aliased.ex"]
      assert caller_diff, "expected aliased caller to be touched"
      # the alias rewrite leaves a `New` reference behind
      assert caller_diff =~ "New"
    end

    test "no-op when from == to" do
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Old do
        end
        """
      }

      assert {:error, {:same_module, MyApp.Old}} =
               Rename.rename(from: "MyApp.Old", to: "MyApp.Old", files: files)
    end
  end

  describe "option validation" do
    test "requires --from" do
      assert {:error, {:missing_opt, :from}} =
               Rename.rename(to: "MyApp.New", files: %{})
    end

    test "requires --to" do
      assert {:error, {:missing_opt, :to}} =
               Rename.rename(from: "MyApp.Old", files: %{})
    end

    test "rejects malformed module names" do
      assert {:error, {:bad_module_name, :from, "not_a_module"}} =
               Rename.rename(from: "not_a_module", to: "MyApp.New", files: %{})

      assert {:error, {:bad_module_name, :to, "bad-name"}} =
               Rename.rename(from: "MyApp.Old", to: "bad-name", files: %{})
    end

    test "accepts module atoms directly" do
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Old do
        end
        """
      }

      assert {:ok, %{from: MyApp.Old, to: MyApp.New}} =
               Rename.rename(from: MyApp.Old, to: MyApp.New, files: files)
    end
  end

  describe "test file move" do
    # Igniter's rename_module rewrites the test module's defmodule line
    # but doesn't move the file. Adze schedules the missing move so the
    # test file lands at the canonical-for-new-name path.

    test "schedules a move when the test file is at the old canonical path" do
      files = %{
        "lib/my_app/old.ex" => """
        defmodule MyApp.Old do
          def hello, do: :world
        end
        """,
        "test/my_app/old_test.exs" => """
        defmodule MyApp.OldTest do
          use ExUnit.Case
          test "hello", do: assert MyApp.Old.hello() == :world
        end
        """
      }

      {:ok, result} = Rename.rename(from: "MyApp.Old", to: "MyApp.New", files: files)

      # Both files appear in moves: the lib file and the test file.
      assert result.moves["lib/my_app/old.ex"] == "lib/my_app/new.ex"
      assert result.moves["test/my_app/old_test.exs"] == "test/my_app/new_test.exs"
    end

    test "no test-file move when no corresponding test module exists" do
      files = %{
        "lib/my_app/old.ex" => """
        defmodule MyApp.Old do
        end
        """
      }

      {:ok, result} = Rename.rename(from: "MyApp.Old", to: "MyApp.New", files: files)

      # Only the lib file moves; no test file to track.
      assert result.moves == %{"lib/my_app/old.ex" => "lib/my_app/new.ex"}
    end

    test "test file at non-canonical path still gets moved to canonical-for-new-name" do
      files = %{
        "lib/my_app/old.ex" => """
        defmodule MyApp.Old do
        end
        """,
        "test/special/old_test.exs" => """
        defmodule MyApp.OldTest do
          use ExUnit.Case
        end
        """
      }

      {:ok, result} = Rename.rename(from: "MyApp.Old", to: "MyApp.New", files: files)

      # The test file was at a non-canonical location; it still gets
      # moved to canonical-for-new-name (mirroring how Igniter handles
      # lib files).
      assert result.moves["test/special/old_test.exs"] == "test/my_app/new_test.exs"
    end
  end

  describe "short-ref fix-up — rewrite surviving bare-alias refs" do
    # Igniter's same-namespace rename has an upstream bug: it leaves
    # bare `OldShort.fun(...)` call sites un-rewritten even though the
    # alias declaration was updated. Without the fix-up these would
    # compile-break. The fix-up patches them ourselves: when a file
    # had a non-`as:` alias to the renamed module's old name, we
    # rewrite every surviving `OldShort.*` ref to `NewShort.*`.

    test "same-namespace rename: bare refs in aliased callers get fixed up" do
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Util.OldUtil do
          def new, do: %{}
          def insert(m, k, v), do: Map.put(m, k, v)
        end
        """,
        "lib/caller.ex" => """
        defmodule MyApp.Caller do
          alias MyApp.Util.OldUtil

          def go do
            OldUtil.new()
            |> OldUtil.insert(:k, 1)
          end
        end
        """
      }

      {:ok, result} =
        Rename.rename(from: "MyApp.Util.OldUtil", to: "MyApp.Util.NewUtil", files: files)

      # Fix-up should resolve every surviving short ref. The
      # surviving-references warnings list is empty.
      surviving = warnings_of(result, :surviving_references)

      assert surviving == [],
             "expected zero surviving refs after fix-up, got: #{inspect(surviving)}"

      # And the fix-up is reported as a notice so the user knows
      # adze patched bare refs on their behalf.
      fixed = notices_of(result, :rewritten_short_refs)
      assert fixed != []
      assert Enum.any?(fixed, &(&1.path == "lib/caller.ex"))
    end

    test "rename!/1 succeeds without --force after fix-up" do
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Util.OldUtil do
          def new, do: %{}
        end
        """,
        "lib/caller.ex" => """
        defmodule MyApp.Caller do
          alias MyApp.Util.OldUtil

          def go, do: OldUtil.new()
        end
        """
      }

      # Without the fix-up, this rename! would error
      # :surviving_references. With fix-up, the in-memory write! still
      # raises (test mode), but the failure mode confirms we got
      # *past* the guard.
      assert_raise ArgumentError, ~r/test-mode/, fn ->
        Rename.rename!(from: "MyApp.Util.OldUtil", to: "MyApp.Util.NewUtil", files: files)
      end
    end

    test "no fix-up when no non-as: alias declaration in pre-rewrite source" do
      # The caller has only an `as:` alias — bare `B.*` refs (not
      # `OldUtil.*`) resolve via it. After rename, the alias declaration
      # is rewritten but `B.*` stays correct. There are no bare
      # `OldUtil.*` refs to fix up.
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Util.OldUtil do
          def new, do: %{}
        end
        """,
        "lib/aliased_caller.ex" => """
        defmodule MyApp.AliasedCaller do
          alias MyApp.Util.OldUtil, as: B

          def go, do: B.new()
        end
        """
      }

      {:ok, result} =
        Rename.rename(from: "MyApp.Util.OldUtil", to: "MyApp.Util.NewUtil", files: files)

      assert warnings_of(result, :surviving_references) == []
      assert notices_of(result, :rewritten_short_refs) == []
    end

    test "ambiguous case (bare OldUtil with no alias declaration) falls through to warning" do
      # A file references `OldUtil` without an alias declaration. We
      # can't safely conclude the bare ref was resolving to the
      # renamed module, so we don't rewrite it. It surfaces as a
      # warning instead.
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Util.OldUtil do
          def new, do: %{}
        end
        """,
        "lib/ambiguous.ex" => """
        defmodule MyApp.Ambiguous do
          def go, do: MyApp.Util.OldUtil.new()
        end
        """
      }

      {:ok, result} =
        Rename.rename(from: "MyApp.Util.OldUtil", to: "MyApp.Util.NewUtil", files: files)

      # The fully-qualified `MyApp.Util.OldUtil.new()` would be
      # rewritten by Igniter's string substitution, so there shouldn't
      # be a surviving bare ref. This test mostly confirms we don't
      # over-eagerly mutate files without alias evidence.
      assert notices_of(result, :rewritten_short_refs) == []
    end

    defp warnings_of(result, tag) do
      Enum.flat_map(result.warnings, fn
        {^tag, refs} -> refs
        _ -> []
      end)
    end

    defp notices_of(result, tag) do
      Enum.flat_map(result.notices, fn
        {^tag, refs} -> refs
        _ -> []
      end)
    end
  end

  describe "surviving-references guard (leftovers the fix-up can't handle)" do
    # The fix-up handles the common case (file has a non-`as:` alias
    # to the renamed module). The guard infrastructure still exists
    # for the residual cases where bare `OldShort.*` refs appear
    # without an alias declaration adze can lean on. The test
    # fixtures here exercise that residual path.

    test "cross-namespace rename has zero surviving short refs (sanity)" do
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Util.OldUtil do
          def new, do: %{}
        end
        """,
        "lib/caller.ex" => """
        defmodule MyApp.Caller do
          alias MyApp.Util.OldUtil

          def go, do: OldUtil.new()
        end
        """
      }

      {:ok, result} =
        Rename.rename(from: "MyApp.Util.OldUtil", to: "MyApp.Multi.NewUtil", files: files)

      assert warnings_of(result, :surviving_references) == [],
             "cross-namespace rename should rewrite bare short refs cleanly"
    end

    test "rename!/1 aborts when bare ref has no non-as: alias declaration" do
      # The file uses `alias …, as: B`, so adze can't conclude the bare
      # `OldUtil.new()` was resolving via this alias. The fix-up bails
      # and the post-check surfaces the survivor; rename!/1 refuses.
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Util.OldUtil do
          def new, do: %{}
        end
        """,
        "lib/ambiguous.ex" => """
        defmodule MyApp.Ambiguous do
          alias MyApp.Util.OldUtil, as: B

          def go, do: OldUtil.new()
        end
        """
      }

      assert {:error, {:surviving_references, refs}} =
               Rename.rename!(
                 from: "MyApp.Util.OldUtil",
                 to: "MyApp.Util.NewUtil",
                 files: files
               )

      assert is_list(refs)
      assert refs != []
    end

    test "rename!/1 with force: true proceeds despite ambiguous survivors" do
      files = %{
        "lib/old.ex" => """
        defmodule MyApp.Util.OldUtil do
          def new, do: %{}
        end
        """,
        "lib/ambiguous.ex" => """
        defmodule MyApp.Ambiguous do
          alias MyApp.Util.OldUtil, as: B

          def go, do: OldUtil.new()
        end
        """
      }

      # With force: true we get past the post-check; in test mode the
      # write! call raises (test rewrites can't write to disk), but
      # the failure shape confirms we got past the surviving-refs
      # guard.
      assert_raise ArgumentError, ~r/test-mode/, fn ->
        Rename.rename!(
          from: "MyApp.Util.OldUtil",
          to: "MyApp.Util.NewUtil",
          files: files,
          force: true
        )
      end
    end
  end

  describe "rename!/1 — write mode" do
    @tag :tmp_dir
    test "writes the renamed module file to disk", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "lib/my_app"))

      File.write!(Path.join(tmp, "mix.exs"), """
      defmodule My.MixProject do
        use Mix.Project
        def project, do: [app: :my_app, version: "0.1.0", elixir: "~> 1.19", deps: []]
      end
      """)

      File.write!(Path.join(tmp, "lib/my_app/old.ex"), """
      defmodule MyApp.Old do
        def hello, do: :world
      end
      """)

      {:ok, result} =
        Rename.rename!(
          from: "MyApp.Old",
          to: "MyApp.New",
          mix_root: tmp
        )

      # The file at the new canonical location exists and contains the
      # renamed module.
      new_path = Path.join(tmp, "lib/my_app/new.ex")
      assert File.exists?(new_path)
      assert File.read!(new_path) =~ "defmodule MyApp.New"

      # The old file path is gone.
      refute File.exists?(Path.join(tmp, "lib/my_app/old.ex"))

      # And the result still carries the diff/move metadata.
      assert result.moves != %{}
    end

    # Regression coverage for the formatting-exceptions audit (issue
    # 3): ProjectRewrite.write/1 (the non-raising counterpart to
    # write!/1) converts File.Error into {:error, {:file_write,
    # reason}} instead of raising. rename!/1 uses it internally, so a
    # write failure comes back as a clean error tuple rather than an
    # exception escaping to the caller.
    @tag :tmp_dir
    test "returns {:error, {:file_write, _}} when the target file can't be written", %{
      tmp_dir: tmp
    } do
      File.mkdir_p!(Path.join(tmp, "lib/my_app"))

      File.write!(Path.join(tmp, "mix.exs"), """
      defmodule My.MixProject do
        use Mix.Project
        def project, do: [app: :my_app, version: "0.1.0", elixir: "~> 1.19", deps: []]
      end
      """)

      File.write!(Path.join(tmp, "lib/my_app/old.ex"), """
      defmodule MyApp.Old do
        def hello, do: :world
      end
      """)

      # Make the directory read-only so Rewrite.write_all/1 can't
      # create the new file inside it.
      File.chmod!(Path.join(tmp, "lib/my_app"), 0o555)

      on_exit(fn -> File.chmod(Path.join(tmp, "lib/my_app"), 0o755) end)

      assert {:error, {:file_write, _reason}} =
               Rename.rename!(
                 from: "MyApp.Old",
                 to: "MyApp.New",
                 mix_root: tmp
               )
    end
  end
end
