defmodule Hivebeam.Application do
  @moduledoc false
  use Application

  require Logger

  alias Hivebeam.Gateway.Config, as: GatewayConfig

  @impl true
  def start(_type, _args) do
    :ok = GatewayConfig.require_token!()

    if GatewayConfig.debug_enabled?() do
      :ok = Logger.configure(level: :debug)
      Logger.debug("Hivebeam gateway debug mode enabled")
    end

    children = [
      {Hivebeam.Gateway.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: Hivebeam.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
