defmodule HivebeamLiveview.MixProject do
  use Mix.Project

  def project do
    [
      app: :hivebeam_liveview,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {HivebeamLiveview.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:hivebeam, path: "../.."},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:plug_cowboy, "~> 2.7"}
    ]
  end
end
