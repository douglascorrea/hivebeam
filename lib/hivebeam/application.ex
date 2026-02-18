defmodule Hivebeam.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Hivebeam.ClusterConnector, []},
      {Hivebeam.CodexBridge, []}
    ]

    opts = [strategy: :one_for_one, name: Hivebeam.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
