defmodule AdzeCLITest do
  # chmod on a shared tmp dir; keep it serial.
  use ExUnit.Case, async: false

  alias Adze.CLI

  @tmpdir System.tmp_dir!()

  setup do
    root = Path.join(@tmpdir, "adze_cli_#{System.unique_integer([:positive])}")
    lib = Path.join(root, "lib")
    File.mkdir_p!(lib)

    source = Path.join(lib, "s.ex")
    content = "defmodule S do\n  def a(x), do: b(x)\n  def b(x), do: x\nend\n"
    File.write!(source, content)

    on_exit(fn ->
      File.chmod(lib, 0o755)
      File.chmod(source, 0o644)
      File.rm_rf!(root)
    end)

    %{root: root, lib: lib, source: source, content: content}
  end

  describe "write failures are reported, not raised" do
    # ProjectRewrite.write/1 rolls back and returns a *list* of reasons;
    # the CLI must render it rather than handing it to :file.format_error/1.
    test "extract! into a read-only lib/", ctx do
      File.chmod!(ctx.lib, 0o555)

      error =
        assert_raise Mix.Error, fn ->
          CLI.main(
            ~w(extract! --file #{ctx.source} --definition b/1 --module Zed.B --mix-root #{ctx.root})
          )
        end

      assert error.message =~ "could not write: "
      assert error.message =~ "permission denied"
      assert File.read!(ctx.source) == ctx.content
      refute File.exists?(Path.join(ctx.lib, "zed/b.ex"))
    end

    test "mv! onto a read-only file", ctx do
      File.chmod!(ctx.source, 0o444)

      error =
        assert_raise Mix.Error, fn ->
          CLI.main(~w(mv! --file #{ctx.source} --definition b/1 --before a/1))
        end

      assert error.message == "could not write #{ctx.source}: permission denied"
      assert File.read!(ctx.source) == ctx.content
    end
  end
end
