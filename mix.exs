defmodule Hivebeam.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :hivebeam,
      version: @version,
      elixir: "~> 1.18",
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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:acpex, path: "vendor/acpex"},
      {:term_ui, git: "https://github.com/pcharbon70/term_ui.git"},
      {:libcluster, "~> 3.5"}
    ]
  end
end
