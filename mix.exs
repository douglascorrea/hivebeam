defmodule Hivebeam.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :hivebeam,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Hivebeam.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp releases do
    [
      hivebeam: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  # Run "mix help deps" to learn about applications.
  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.10", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
