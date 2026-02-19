defmodule Hivebeam.Gateway.EventLog do
  @moduledoc false

  alias Hivebeam.Gateway.Store

  @spec append(String.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def append(gateway_session_key, kind, source, payload)
      when is_binary(gateway_session_key) and is_binary(kind) and is_binary(source) and
             is_map(payload) do
    Store.append_event(gateway_session_key, kind, source, payload)
  end

  @spec replay(String.t(), integer(), pos_integer()) ::
          {:ok, %{events: [map()], next_after_seq: integer(), has_more: boolean()}}
          | {:error, term()}
  def replay(gateway_session_key, after_seq, limit)
      when is_binary(gateway_session_key) and is_integer(after_seq) and is_integer(limit) and
             limit > 0 do
    Store.read_events(gateway_session_key, after_seq, limit)
  end

  @spec prune(String.t()) :: :ok | {:error, term()}
  def prune(gateway_session_key) when is_binary(gateway_session_key) do
    Store.prune_session_events(gateway_session_key)
  end
end
