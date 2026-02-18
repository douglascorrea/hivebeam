defmodule Hivebeam.ClusterConnectorTest do
  use ExUnit.Case, async: false

  alias Hivebeam.ClusterConnector

  test "stores configured peers" do
    name = :"cluster_connector_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ClusterConnector.start_link(
        name: name,
        config: %{cluster_nodes: [:"codex@node-a", :"codex@node-b"], cluster_retry_ms: 60_000}
      )

    on_exit(fn -> Process.alive?(pid) && GenServer.stop(pid) end)

    assert ClusterConnector.peers(name) == [:"codex@node-a", :"codex@node-b"]
  end

  test "skips connect attempts when node distribution is disabled" do
    unless Node.alive?() do
      parent = self()
      name = :"cluster_connector_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        ClusterConnector.start_link(
          name: name,
          connect_fun: fn node ->
            send(parent, {:connect_attempt, node})
            true
          end,
          config: %{cluster_nodes: [:"codex@node-a"], cluster_retry_ms: 60_000}
        )

      on_exit(fn -> Process.alive?(pid) && GenServer.stop(pid) end)

      refute_receive {:connect_attempt, _}, 100
    end
  end
end
