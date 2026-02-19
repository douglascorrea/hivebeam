defmodule Hivebeam.Acp.Adapter do
  @moduledoc false

  alias Hivebeam.Acp.JsonRpcConnection

  @spec start_client(module(), keyword(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_client(handler_module, handler_args, opts)
      when is_atom(handler_module) and is_list(handler_args) and is_list(opts) do
    agent_path = Keyword.fetch!(opts, :agent_path)
    agent_args = Keyword.get(opts, :agent_args, [])

    JsonRpcConnection.start_link(
      handler_module: handler_module,
      handler_args: handler_args,
      agent_path: agent_path,
      agent_args: agent_args
    )
  end
end
