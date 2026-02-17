defmodule ElxDockerNode.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :elx_docker_node,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {ElxDockerNode.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:acpex, "~> 0.1"}
    ]
  end
end
