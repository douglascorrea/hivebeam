defmodule Hivebeam.CodexBridgeIntegrationTest do
  use ExUnit.Case, async: false

  alias Hivebeam.Codex
  alias Hivebeam.CodexBridge

  @integration_enabled System.get_env("RUN_INTEGRATION") == "1"
  @tag :integration
  @tag skip: not @integration_enabled
  test "local bridge can prompt codex-acp via docker container" do
    bridge_name = :"integration_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        config: %{
          acp_command: {"docker", ["compose", "exec", "-T", "codex-node", "codex-acp"]},
          reconnect_ms: 250
        }
      )

    on_exit(fn -> Process.alive?(bridge_pid) && GenServer.stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.connected
    end)

    assert {:ok, result} =
             CodexBridge.prompt("Reply with exactly INTEGRATION_OK",
               bridge_name: bridge_name,
               timeout: 120_000
             )

    assert result.stop_reason in ["done", "error", "cancelled"]
  end

  @tag :integration
  @tag skip: not @integration_enabled
  test "remote erpc prompt works when distributed node is configured" do
    remote_node = System.get_env("ELX_INTEGRATION_REMOTE_NODE")

    if is_nil(remote_node) do
      assert true
    else
      assert {:ok, _result} =
               Codex.prompt(String.to_atom(remote_node), "Reply with exactly REMOTE_OK",
                 timeout: 120_000
               )
    end
  end

  @tag :integration
  @tag skip: not @integration_enabled
  test "bridge reconnects after codex process drops" do
    bridge_name = :"integration_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        config: %{
          acp_command: {"docker", ["compose", "exec", "-T", "codex-node", "codex-acp"]},
          reconnect_ms: 250
        }
      )

    on_exit(fn -> Process.alive?(bridge_pid) && GenServer.stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.connected and is_pid(status.connection_pid)
    end)

    {:ok, status_before} = CodexBridge.status(bridge_name)
    Process.exit(status_before.connection_pid, :kill)

    wait_until(fn ->
      {:ok, status_after} = CodexBridge.status(bridge_name)

      status_after.connected and is_pid(status_after.connection_pid) and
        status_after.connection_pid != status_before.connection_pid
    end)
  end

  defp wait_until(fun, attempts \\ 120)

  defp wait_until(_fun, 0), do: flunk("condition was not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      wait_until(fun, attempts - 1)
    end
  end
end
