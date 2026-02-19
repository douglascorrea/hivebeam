defmodule Hivebeam.Gateway.Supervisor do
  @moduledoc false
  use Supervisor

  alias Hivebeam.Gateway.Config
  alias Hivebeam.Gateway.HTTP.Server
  alias Hivebeam.Gateway.SessionSupervisor
  alias Hivebeam.Gateway.Store

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Hivebeam.Gateway.WorkerRegistry},
      {Registry, keys: :duplicate, name: Hivebeam.Gateway.EventRegistry},
      {Store,
       [data_dir: Config.data_dir(), max_events_per_session: Config.max_events_per_session()]},
      {SessionSupervisor, []},
      {Server, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
