defmodule Mix.Tasks.Claude.Bridge.Run do
  use Mix.Task

  @shortdoc "Starts the Claude ACP bridge and blocks"

  @impl Mix.Task
  def run(args) do
    System.put_env("HIVEBEAM_ACP_PROVIDER", "claude")
    System.put_env("HIVEBEAM_CODEX_BRIDGE_NAME", "Hivebeam.ClaudeBridge")
    Mix.Task.run("codex.bridge.run", args)
  end
end
