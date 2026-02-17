defmodule ElxDockerNode.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {ElxDockerNode.ClusterConnector, []},
      {ElxDockerNode.CodexBridge, []}
    ]

    opts = [strategy: :one_for_one, name: ElxDockerNode.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
