defmodule Hivebeam.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :hivebeam,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Hivebeam.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:acpex, "~> 0.1"},
      {:term_ui, git: "https://github.com/pcharbon70/term_ui.git"}
    ]
  end
end
