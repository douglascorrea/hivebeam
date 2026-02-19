defmodule Hivebeam.Gateway.HTTP.Server do
  @moduledoc false

  alias Hivebeam.Gateway.Config
  alias Hivebeam.Gateway.HTTP.Router
  alias Hivebeam.Gateway.WS.Handler

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts \\ []) do
    dispatch = [
      {:_,
       [
         {"/v1/ws", Handler, %{}},
         {"/[...]", Plug.Cowboy.Handler, {Router, []}}
       ]}
    ]

    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: Router,
      options: [ip: Config.bind_ip(), port: Config.bind_port()],
      dispatch: dispatch
    )
  end
end
