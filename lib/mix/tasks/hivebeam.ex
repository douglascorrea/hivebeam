defmodule Mix.Tasks.Hivebeam do
  use Mix.Task

  @shortdoc "Hivebeam gateway CLI entrypoint"

  @impl Mix.Task
  def run(["gateway", "run" | rest]) do
    Mix.Task.reenable("hivebeam.gateway.run")
    Mix.Tasks.Hivebeam.Gateway.Run.run(rest)
  end

  def run(_args) do
    Mix.shell().info("""
    Usage:
      mix hivebeam gateway run [--bind 0.0.0.0:8080] [--token <token>] [--data-dir <path>] [--sandbox-root <path>] [--sandbox-default-root <path>] [--dangerously]
    """)
  end
end
