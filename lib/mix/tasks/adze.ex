defmodule Mix.Tasks.Adze do
  @shortdoc "Structural Elixir refactoring + outline-first exploration"

  @moduledoc """
  Run from the root of an Elixir project that depends on adze
  (typically `{:adze, ..., only: [:dev]}` in `mix.exs`). The mix
  task reads `Mix.Project.config()` (formatter opts,
  `elixirc_paths`) and `Application.get_env(:adze, :include_attrs)`
  from the loaded project.

  See `mix adze --help` for the op list, or read `README.md`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # rename / rename! go through Igniter, which uses the `:rewrite`
    # OTP app's TaskSupervisor. Make sure the dependency chain is up
    # before we hand off to the CLI dispatcher.
    {:ok, _} = Application.ensure_all_started(:igniter)
    Adze.CLI.main(argv)
  end
end
