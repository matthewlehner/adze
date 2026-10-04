defmodule Adze.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/matthewlehner/adze"

  def project do
    [
      app: :adze,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [&String.contains?(&1, "/fixtures/")],
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      docs: docs(),
      package: package(),
      name: "Adze",
      description:
        "Structural Elixir refactoring and outline-first code exploration. Built on Sourceror and Igniter.",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :igniter]
    ]
  end

  defp deps do
    [
      {:sourceror, "~> 1.7"},
      {:igniter, "~> 0.8"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      lint: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "dialyzer"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      groups_for_modules: [
        "Read-Only Analysis": [
          Adze.Outline,
          Adze.Deps,
          Adze.LsDeps,
          Adze.Aliases,
          Adze.FindCallers
        ],
        Refactoring: [
          Adze.Move,
          Adze.Extract,
          Adze.ExtractPrivate,
          Adze.Rename
        ],
        Internals: [
          Adze.Definition,
          Adze.Diff,
          Adze.Formatter,
          Adze.ProjectRewrite,
          Adze.Types,
          Adze.CLI
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(
        lib
        mix.exs
        README.md
        CHANGELOG.md
        LICENSE
        .formatter.exs
        skill.md
        agents-snippet.md
      )
    ]
  end
end
