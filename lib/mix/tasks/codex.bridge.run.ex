defmodule Mix.Tasks.Codex.Bridge.Run do
  use Mix.Task

  @shortdoc "Starts the Codex ACP bridge and blocks"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    if Node.alive?() do
      Mix.shell().info("Distributed node started as #{Node.self()}")
    else
      Mix.shell().info("Node is not distributed. Use --name/--cookie for cross-node calls.")
    end

    case Hivebeam.Codex.status() do
      {:ok, status} ->
        Mix.shell().info(
          "Bridge status=#{status.status} session_id=#{inspect(status.session_id)} connected=#{status.connected}"
        )

        if not status.connected and not is_nil(status.last_error) do
          Mix.shell().info("Bridge last_error=#{inspect(status.last_error)}")
        end

      {:error, reason} ->
        Mix.shell().error("Could not fetch bridge status: #{inspect(reason)}")
    end

    Process.sleep(:infinity)
  end
end
