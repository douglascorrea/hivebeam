defmodule Hivebeam.Application do
  @moduledoc false
  use Application

  alias Hivebeam.Gateway.Config, as: GatewayConfig

  @impl true
  def start(_type, _args) do
    :ok = GatewayConfig.require_token!()

    children = [
      {Hivebeam.Gateway.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: Hivebeam.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
