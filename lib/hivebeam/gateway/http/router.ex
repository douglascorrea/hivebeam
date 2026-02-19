defmodule Hivebeam.Gateway.HTTP.Router do
  @moduledoc false
  use Plug.Router

  alias Hivebeam.Gateway.SessionRouter

  plug :match
  plug Hivebeam.Gateway.HTTP.Auth
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :dispatch

  get "/healthz" do
    send_json(conn, 200, %{status: "ok"})
  end

  post "/v1/sessions" do
    attrs = if is_map(conn.body_params), do: conn.body_params, else: %{}

    case SessionRouter.create_session(attrs) do
      {:ok, session} ->
        send_json(conn, 200, session_payload(session))

      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/sessions/:gateway_session_key" do
    case SessionRouter.get_session(gateway_session_key) do
      {:ok, session} ->
        send_json(conn, 200, session_payload(session))

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "session_not_found"})

      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/sessions/:gateway_session_key/attach" do
    after_seq = parse_integer(value(conn.body_params, "after_seq"), 0)
    limit = parse_integer(value(conn.body_params, "limit"), 1_000)

    with {:ok, session} <- SessionRouter.get_session(gateway_session_key),
         {:ok, _pid} <- SessionRouter.ensure_worker(gateway_session_key, recovered?: true),
         {:ok, replay} <- SessionRouter.events(gateway_session_key, after_seq, limit) do
      send_json(conn, 200, %{
        session: session_payload(session),
        events: replay.events,
        next_after_seq: replay.next_after_seq,
        has_more: replay.has_more
      })
    else
      {:error, :not_found} ->
        send_json(conn, 404, %{error: "session_not_found"})

      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/sessions/:gateway_session_key/prompts" do
    request_id = value(conn.body_params, "request_id")
    text = value(conn.body_params, "text")
    timeout_ms = value(conn.body_params, "timeout_ms")

    cond do
      not is_binary(request_id) or request_id == "" ->
        send_json(conn, 422, %{error: "request_id is required"})

      not is_binary(text) or text == "" ->
        send_json(conn, 422, %{error: "text is required"})

      true ->
        case SessionRouter.prompt(gateway_session_key, request_id, text, timeout_ms) do
          {:ok, result} ->
            send_json(conn, 200, result)

          {:error, :not_found} ->
            send_json(conn, 404, %{error: "session_not_found"})

          {:error, reason} ->
            send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  post "/v1/sessions/:gateway_session_key/cancel" do
    case SessionRouter.cancel(gateway_session_key) do
      {:ok, result} -> send_json(conn, 200, result)
      {:error, :not_found} -> send_json(conn, 404, %{error: "session_not_found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/sessions/:gateway_session_key/events" do
    after_seq = parse_integer(value(conn.query_params, "after_seq"), 0)
    limit = parse_integer(value(conn.query_params, "limit"), 200)

    case SessionRouter.events(gateway_session_key, after_seq, limit) do
      {:ok, payload} -> send_json(conn, 200, payload)
      {:error, :not_found} -> send_json(conn, 404, %{error: "session_not_found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/sessions/:gateway_session_key/approvals" do
    approval_ref = value(conn.body_params, "approval_ref")
    decision = value(conn.body_params, "decision")

    cond do
      not is_binary(approval_ref) or approval_ref == "" ->
        send_json(conn, 422, %{error: "approval_ref is required"})

      decision not in ["allow", "deny"] ->
        send_json(conn, 422, %{error: "decision must be allow or deny"})

      true ->
        case SessionRouter.approve(gateway_session_key, approval_ref, decision) do
          {:ok, payload} -> send_json(conn, 200, payload)
          {:error, :approval_not_found} -> send_json(conn, 404, %{error: "approval_not_found"})
          {:error, :not_found} -> send_json(conn, 404, %{error: "session_not_found"})
          {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  delete "/v1/sessions/:gateway_session_key" do
    case SessionRouter.close(gateway_session_key) do
      {:ok, _session} -> send_json(conn, 200, %{closed: true})
      {:error, :not_found} -> send_json(conn, 404, %{error: "session_not_found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp session_payload(session) do
    %{
      gateway_session_key: session.gateway_session_key,
      status: session.status,
      provider: session.provider,
      created_at: session.created_at,
      last_seq: session.last_seq,
      upstream_session_id: session.upstream_session_id,
      connected: session.connected,
      in_flight: session.in_flight
    }
  end

  defp send_json(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {atom_key, value} when is_atom(atom_key) ->
            if Atom.to_string(atom_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp value(_map, _key), do: nil

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default
end
