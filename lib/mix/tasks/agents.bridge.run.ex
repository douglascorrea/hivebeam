defmodule Mix.Tasks.Agents.Bridge.Run do
  use Mix.Task

  alias Hivebeam.BridgeCatalog
  alias Hivebeam.Codex
  alias Hivebeam.CodexBridge
  alias Hivebeam.CodexConfig

  @shortdoc "Starts all available ACP bridges (codex + claude) and blocks"

  @impl Mix.Task
  def run(_args) do
    # Keep codex as the default bridge name for backward compatibility.
    System.put_env("HIVEBEAM_ACP_PROVIDER", "codex")
    Mix.Task.run("app.start")

    Enum.each(BridgeCatalog.providers(), fn
      %{provider: "codex"} ->
        :ok

      %{provider: provider, bridge_name: bridge_name} ->
        ensure_optional_bridge(provider, bridge_name)
    end)

    Enum.each(BridgeCatalog.providers(), fn %{provider: provider, bridge_name: bridge_name} ->
      print_bridge_status(provider, bridge_name)
    end)

    Process.sleep(:infinity)
  end

  defp ensure_optional_bridge(provider, bridge_name) do
    case CodexConfig.acp_command(provider) do
      {:ok, command} ->
        if CodexConfig.command_available?(command) do
          child_spec =
            Supervisor.child_spec(
              {CodexBridge,
               [
                 name: bridge_name,
                 config: %{
                   acp_provider: provider,
                   acp_command: command
                 }
               ]},
              id: {:hivebeam_bridge, provider}
            )

          case Supervisor.start_child(Hivebeam.Supervisor, child_spec) do
            {:ok, _pid} ->
              Mix.shell().info("Started #{provider} bridge (#{inspect(bridge_name)})")

            {:error, {:already_started, _pid}} ->
              Mix.shell().info("#{provider} bridge already running (#{inspect(bridge_name)})")

            {:error, reason} ->
              Mix.shell().error("Could not start #{provider} bridge: #{inspect(reason)}")
          end
        else
          Mix.shell().info("Skipping #{provider} bridge (command not found): #{inspect(command)}")
        end

      {:error, reason} ->
        Mix.shell().info("Skipping #{provider} bridge (invalid config): #{inspect(reason)}")
    end
  end

  defp print_bridge_status(provider, bridge_name) do
    case Codex.status(nil, bridge_name: bridge_name) do
      {:ok, status} ->
        Mix.shell().info(
          "[#{provider}] status=#{status.status} connected=#{status.connected} session_id=#{status.session_id || "-"}"
        )

      {:error, reason} ->
        Mix.shell().error("[#{provider}] status unavailable: #{inspect(reason)}")
    end
  end
end
