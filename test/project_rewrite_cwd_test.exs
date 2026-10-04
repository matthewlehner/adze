defmodule AdzeProjectRewriteCwdTest do
  # async: false — these tests change the VM-global cwd.
  use ExUnit.Case, async: false

  alias Adze.ProjectRewrite

  defp make_project(root, mod) do
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule #{mod}.MixProject do
      use Mix.Project
      def project, do: [app: :x, version: "0.1.0", deps: []]
    end
    """)

    File.write!(Path.join(root, "lib/#{Macro.underscore(mod)}.ex"), """
    defmodule #{mod} do
    end
    """)
  end

  defp source_paths(%ProjectRewrite{igniter: igniter}) do
    igniter.rewrite |> Rewrite.sources() |> Enum.map(& &1.path) |> Enum.sort()
  end

  @tag :tmp_dir
  test "concurrent rewrites on different roots each see only their own files",
       %{tmp_dir: tmp} do
    a = Path.join(tmp, "a")
    b = Path.join(tmp, "b")
    make_project(a, "Alpha")
    make_project(b, "Beta")
    cwd = File.cwd!()

    results =
      for i <- 1..20 do
        root = if rem(i, 2) == 0, do: a, else: b
        {root, Task.async(fn -> ProjectRewrite.new(mix_root: root) end)}
      end
      |> Enum.map(fn {root, task} -> {root, Task.await(task, 30_000)} end)

    for {root, {:ok, rewrite}} <- results do
      expected = if root == a, do: ["lib/alpha.ex"], else: ["lib/beta.ex"]
      assert source_paths(rewrite) == expected
    end

    assert File.cwd!() == cwd
  end
end
