defmodule Hivebeam.Acp.ClientHandler do
  @moduledoc false

  @callback init(keyword()) :: {:ok, state :: term()}
  @callback handle_request(String.t(), map(), state :: term()) ::
              {:ok, map(), state :: term()}
              | {:error, map(), state :: term()}
              | {:noreply, state :: term()}
  @callback handle_notification(String.t(), map(), state :: term()) ::
              {:noreply, state :: term()}
  @callback handle_info(term(), state :: term()) ::
              {:noreply, state :: term()} | {:stop, term(), state :: term()}

  @optional_callbacks handle_info: 2
end
