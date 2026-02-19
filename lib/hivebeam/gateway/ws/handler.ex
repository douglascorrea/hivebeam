defmodule Hivebeam.Gateway.WS.Handler do
  @moduledoc false
  @behaviour :cowboy_websocket

  alias Hivebeam.Gateway.HTTP.Auth
  alias Hivebeam.Gateway.SessionRouter

  @impl true
  def init(req, state) do
    case Auth.authorized_cowboy_req?(req) do
      :ok ->
        {session_key, after_seq} = parse_query(req)

        websocket_state = %{
          session_key: session_key,
          after_seq: after_seq,
          attached?: false,
          closed?: false
        }

        {:cowboy_websocket, req, Map.merge(websocket_state, Map.new(state || []))}

      {:error, _reason} ->
        body = Jason.encode!(%{error: "unauthorized"})
        req = :cowboy_req.reply(401, %{"content-type" => "application/json"}, body, req)
        {:ok, req, %{closed?: true}}
    end
  end

  @impl true
  def websocket_init(%{closed?: true} = state), do: {:ok, state}

  def websocket_init(%{session_key: session_key, after_seq: after_seq} = state)
      when is_binary(session_key) do
    send(self(), {:auto_attach, session_key, after_seq})
    {:ok, state}
  end

  def websocket_init(state), do: {:ok, state}

  @impl true
  def websocket_handle({:text, text}, state) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => "attach"} = payload} ->
        session_key = payload["gateway_session_key"] || payload["session_key"]
        after_seq = parse_integer(payload["after_seq"], 0)
        attach_and_reply(state, session_key, after_seq)

      {:ok, %{"type" => "prompt"} = payload} ->
        with {:ok, session_key} <- attached_session_key(state),
             request_id when is_binary(request_id) <- payload["request_id"],
             text_value when is_binary(text_value) <- payload["text"],
             {:ok, result} <-
               SessionRouter.prompt(session_key, request_id, text_value, payload["timeout_ms"]) do
          {:reply, {:text, encode(%{type: "ack", action: "prompt", data: result})}, state}
        else
          :error -> {:reply, {:text, encode(%{type: "error", error: "invalid_prompt_payload"})}, state}
          {:error, reason} -> {:reply, {:text, encode(%{type: "error", error: inspect(reason)})}, state}
          _ -> {:reply, {:text, encode(%{type: "error", error: "invalid_prompt_payload"})}, state}
        end

      {:ok, %{"type" => "cancel"}} ->
        with {:ok, session_key} <- attached_session_key(state),
             {:ok, result} <- SessionRouter.cancel(session_key) do
          {:reply, {:text, encode(%{type: "ack", action: "cancel", data: result})}, state}
        else
          {:error, reason} -> {:reply, {:text, encode(%{type: "error", error: inspect(reason)})}, state}
        end

      {:ok, %{"type" => "approval"} = payload} ->
        with {:ok, session_key} <- attached_session_key(state),
             approval_ref when is_binary(approval_ref) <- payload["approval_ref"],
             decision when is_binary(decision) <- payload["decision"],
             {:ok, result} <- SessionRouter.approve(session_key, approval_ref, decision) do
          {:reply, {:text, encode(%{type: "ack", action: "approval", data: result})}, state}
        else
          _ -> {:reply, {:text, encode(%{type: "error", error: "invalid_approval_payload"})}, state}
        end

      {:ok, %{"type" => "ping"}} ->
        {:reply, {:text, encode(%{type: "pong"})}, state}

      {:ok, _other} ->
        {:reply, {:text, encode(%{type: "error", error: "unsupported_message_type"})}, state}

      {:error, _reason} ->
        {:reply, {:text, encode(%{type: "error", error: "invalid_json"})}, state}
    end
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  @impl true
  def websocket_info({:auto_attach, session_key, after_seq}, state) do
    attach_and_reply(state, session_key, after_seq)
  end

  def websocket_info({:replay_event, event}, state) do
    {:reply, {:text, encode(%{type: "event", data: event})}, state}
  end

  def websocket_info({:gateway_event, event}, state) do
    {:reply, {:text, encode(%{type: "event", data: event})}, state}
  end

  def websocket_info(_info, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _req, state) do
    if is_binary(Map.get(state, :session_key)) and Map.get(state, :attached?, false) do
      SessionRouter.unsubscribe(state.session_key)
    end

    :ok
  end

  defp attach_and_reply(state, session_key, after_seq)
       when is_binary(session_key) and session_key != "" do
    _ = if Map.get(state, :attached?, false), do: SessionRouter.unsubscribe(state.session_key), else: :ok

    with {:ok, _session} <- SessionRouter.get_session(session_key),
         {:ok, _pid} <- SessionRouter.ensure_worker(session_key, recovered?: true),
         {:ok, _ref} <- SessionRouter.subscribe(session_key, self()),
         {:ok, replay} <- replay_events(session_key, after_seq, 1_000, self()) do

      response =
        encode(%{
          type: "attached",
          gateway_session_key: session_key,
          replayed_count: replay.replayed_count,
          next_after_seq: replay.next_after_seq,
          has_more: replay.has_more
        })

      {:reply, {:text, response},
       %{state | session_key: session_key, after_seq: replay.next_after_seq, attached?: true}}
    else
      {:error, reason} ->
        {:reply, {:text, encode(%{type: "error", error: inspect(reason)})}, state}
    end
  end

  defp attach_and_reply(state, _session_key, _after_seq) do
    {:reply, {:text, encode(%{type: "error", error: "gateway_session_key is required"})}, state}
  end

  defp attached_session_key(%{attached?: true, session_key: session_key}) when is_binary(session_key),
    do: {:ok, session_key}

  defp attached_session_key(_state), do: {:error, :not_attached}

  defp parse_query(req) do
    params = :cowboy_req.parse_qs(req)

    session_key =
      params
      |> Enum.find_value(fn
        {"gateway_session_key", value} -> value
        {"session_key", value} -> value
        _ -> nil
      end)

    after_seq =
      params
      |> Enum.find_value(fn
        {"after_seq", value} -> parse_integer(value, 0)
        _ -> nil
      end)
      |> Kernel.||(0)

    {session_key, after_seq}
  end

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp replay_events(session_key, after_seq, limit, sink) do
    do_replay_events(session_key, after_seq, limit, sink, 0)
  end

  defp do_replay_events(session_key, after_seq, limit, sink, replayed_count) do
    case SessionRouter.events(session_key, after_seq, limit) do
      {:ok, %{events: events, next_after_seq: next_after_seq, has_more: true}} ->
        Enum.each(events, fn event -> send(sink, {:replay_event, event}) end)
        do_replay_events(session_key, next_after_seq, limit, sink, replayed_count + length(events))

      {:ok, %{events: events, next_after_seq: next_after_seq, has_more: false}} ->
        Enum.each(events, fn event -> send(sink, {:replay_event, event}) end)

        {:ok,
         %{
           replayed_count: replayed_count + length(events),
           next_after_seq: next_after_seq,
           has_more: false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode(payload), do: Jason.encode!(payload)
end
