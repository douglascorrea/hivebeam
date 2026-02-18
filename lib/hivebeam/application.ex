defmodule Hivebeam.Application do
  @moduledoc false
  use Application

  alias Hivebeam.CodexConfig

  @impl true
  def start(_type, _args) do
    children =
      [
        {Hivebeam.ClusterConnector, []}
      ]
      |> maybe_add_libcluster()
      |> Kernel.++([{Hivebeam.CodexBridge, []}])

    opts = [strategy: :one_for_one, name: Hivebeam.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_libcluster(children) do
    with true <- CodexConfig.discovery_mode() in ["libcluster", "hybrid"],
         true <- Code.ensure_loaded?(Cluster.Supervisor),
         topologies when is_list(topologies) <- CodexConfig.libcluster_topologies(),
         false <- topologies == [] do
      children ++ [{Cluster.Supervisor, [topologies, [name: Hivebeam.ClusterSupervisor]]}]
    else
      _ -> children
    end
  end
end
