defmodule Hivebeam.ClusterConnector do
  @moduledoc false
  use GenServer

  require Logger

  alias Hivebeam.CodexConfig

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec peers(GenServer.server()) :: [node()]
  def peers(server \\ __MODULE__) do
    GenServer.call(server, :peers)
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, %{})

    state = %{
      peers: Map.get(config, :cluster_nodes, CodexConfig.cluster_nodes()),
      retry_ms: Map.get(config, :cluster_retry_ms, CodexConfig.cluster_retry_ms()),
      connect_fun: Keyword.get(opts, :connect_fun, &Node.connect/1)
    }

    send(self(), :connect_peers)
    {:ok, state}
  end

  @impl true
  def handle_call(:peers, _from, state) do
    {:reply, state.peers, state}
  end

  @impl true
  def handle_info(:connect_peers, state) do
    connect_peers(state)
    Process.send_after(self(), :connect_peers, state.retry_ms)
    {:noreply, state}
  end

  defp connect_peers(state) do
    if Node.alive?() do
      Enum.each(state.peers, fn peer ->
        if peer != Node.self() do
          case state.connect_fun.(peer) do
            true -> Logger.debug("Connected to cluster peer #{peer}")
            false -> Logger.debug("Could not connect to cluster peer #{peer}")
            :ignored -> Logger.debug("Cluster connect ignored for peer #{peer}")
            other -> Logger.debug("Cluster connect returned #{inspect(other)} for peer #{peer}")
          end
        end
      end)
    else
      Logger.debug("Node is not distributed yet. Skipping cluster connect cycle.")
    end
  end
end
