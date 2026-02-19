defmodule Mix.Tasks.Agents.Bridge.Run do
  use Mix.Task

  alias Hivebeam.BridgeCatalog
  alias Hivebeam.Claude
  alias Hivebeam.Codex

  @shortdoc "Starts all available ACP bridges (codex + claude) and blocks"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Enum.each(BridgeCatalog.providers(), fn %{provider: provider, bridge_name: bridge_name} ->
      print_bridge_status(provider, bridge_name)
    end)

    Process.sleep(:infinity)
  end

  defp print_bridge_status(provider, bridge_name) do
    case status_for_provider(provider, bridge_name) do
      {:ok, status} ->
        Mix.shell().info(
          "[#{provider}] status=#{status.status} connected=#{status.connected} session_id=#{status.session_id || "-"}"
        )

      {:error, reason} ->
        Mix.shell().error("[#{provider}] status unavailable: #{inspect(reason)}")
    end
  end

  defp status_for_provider("claude", bridge_name), do: Claude.status(nil, bridge_name: bridge_name)
  defp status_for_provider(_provider, bridge_name), do: Codex.status(nil, bridge_name: bridge_name)
end
