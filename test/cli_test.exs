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
    test "extract into a read-only lib/", ctx do
      File.chmod!(ctx.lib, 0o555)

      error =
        assert_raise Mix.Error, fn ->
          CLI.main(
            ~w(extract --file #{ctx.source} --definition b/1 --module Zed.B --mix-root #{ctx.root})
          )
        end

      assert error.message =~ "could not write: "
      assert error.message =~ "permission denied"
      assert File.read!(ctx.source) == ctx.content
      refute File.exists?(Path.join(ctx.lib, "zed/b.ex"))
    end

    test "mv onto a read-only file", ctx do
      File.chmod!(ctx.source, 0o444)

      error =
        assert_raise Mix.Error, fn ->
          CLI.main(~w(mv --file #{ctx.source} --definition b/1 --before a/1))
        end

      assert error.message == "could not write #{ctx.source}: permission denied"
      assert File.read!(ctx.source) == ctx.content
    end
  end

  describe "--dry-run" do
    test "mv writes by default and prints a summary, not the diff", ctx do
      out =
        ExUnit.CaptureIO.capture_io(fn ->
          CLI.main(~w(mv --file #{ctx.source} --definition b/1 --before a/1))
        end)

      assert File.read!(ctx.source) =~ ~r/def b.*def a/s
      assert out == "# mv\n  updated  #{ctx.source}  (+1 −1)\n"
    end

    test "mv --diff writes and prints the full diff", ctx do
      out =
        ExUnit.CaptureIO.capture_io(fn ->
          CLI.main(~w(mv --file #{ctx.source} --definition b/1 --before a/1 --diff))
        end)

      assert File.read!(ctx.source) =~ ~r/def b.*def a/s
      assert out =~ "--- a\n+++ b\n"
    end

    test "mv --dry-run prints the diff and leaves the file alone", ctx do
      out =
        ExUnit.CaptureIO.capture_io(fn ->
          CLI.main(~w(mv --file #{ctx.source} --definition b/1 --before a/1 --dry-run))
        end)

      assert out =~ "def b(x)"
      assert File.read!(ctx.source) == ctx.content
    end

    test "extract --dry-run creates no target file", ctx do
      ExUnit.CaptureIO.capture_io(fn ->
        CLI.main(
          ~w(extract --file #{ctx.source} --definition b/1 --module Zed.B --mix-root #{ctx.root} --dry-run)
        )
      end)

      assert File.read!(ctx.source) == ctx.content
      refute File.exists?(Path.join(ctx.lib, "zed/b.ex"))
    end
  end

  describe "removed bang ops" do
    for op <- ~w(mv! extract! rename! extract-private!) do
      test "#{op} points at --dry-run" do
        error = assert_raise Mix.Error, fn -> CLI.main([unquote(op)]) end
        assert error.message =~ "`#{unquote(op)}` was removed"
        assert error.message =~ "--dry-run"
      end
    end
  end
end
