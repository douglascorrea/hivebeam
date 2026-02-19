defmodule Hivebeam.Gateway.HttpApiTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Hivebeam.Gateway.HTTP.Router
  alias Hivebeam.Gateway.Store

  defmodule FakeBridge do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(_opts), do: {:ok, %{session_id: "upstream-http", in_flight: false}}

    def status(server) do
      GenServer.call(server, :status)
    end

    def prompt(text, opts) do
      GenServer.call(Keyword.fetch!(opts, :bridge_name), {:prompt, text, opts}, 5_000)
    end

    def cancel_prompt(opts) do
      GenServer.call(Keyword.fetch!(opts, :bridge_name), :cancel)
    end

    @impl true
    def handle_call(:status, _from, state) do
      {:reply,
       {:ok,
        %{
          status: :connected,
          connected: true,
          session_id: state.session_id,
          in_flight_prompt: false,
          approval_mode: :ask
        }}, state}
    end

    def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

    def handle_call({:prompt, _text, opts}, _from, state) do
      stream_to = Keyword.fetch!(opts, :stream_to)
      send(stream_to, {:codex_prompt_stream, %{event: :start}})

      send(
        stream_to,
        {:codex_prompt_stream,
         %{event: :update, update: %{"type" => "agent_message_chunk", "text" => "hi"}}}
      )

      send(stream_to, {:codex_prompt_stream, %{event: :done}})

      {:reply,
       {:ok, %{session_id: state.session_id, stop_reason: "done", message_chunks: ["hi"]}}, state}
    end
  end

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "hivebeam_gateway_http_#{System.unique_integer([:positive])}")

    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)

    System.put_env("HIVEBEAM_GATEWAY_TOKEN", "test-token")

    Application.put_env(:hivebeam, :gateway_bridge_module, FakeBridge)
    Application.put_env(:hivebeam, :gateway_bridge_config, %{})

    start_supervised!({Registry, keys: :unique, name: Hivebeam.Gateway.WorkerRegistry})
    start_supervised!({Registry, keys: :duplicate, name: Hivebeam.Gateway.EventRegistry})
    start_supervised!({Store, [data_dir: data_dir, max_events_per_session: 200]})
    start_supervised!(Hivebeam.Gateway.SessionSupervisor)

    on_exit(fn ->
      Application.delete_env(:hivebeam, :gateway_bridge_module)
      Application.delete_env(:hivebeam, :gateway_bridge_config)
      File.rm_rf!(data_dir)
    end)

    :ok
  end

  test "creates session, prompts, reads events, and closes session" do
    create_body =
      Jason.encode!(%{"provider" => "codex", "cwd" => File.cwd!(), "approval_mode" => "ask"})

    create_conn =
      conn(:post, "/v1/sessions", create_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer test-token")
      |> Router.call(Router.init([]))

    assert create_conn.status == 200
    %{"gateway_session_key" => key} = Jason.decode!(create_conn.resp_body)
    assert is_binary(key)

    prompt_body = Jason.encode!(%{"request_id" => "req-http-1", "text" => "hello"})

    prompt_conn =
      conn(:post, "/v1/sessions/#{key}/prompts", prompt_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer test-token")
      |> Router.call(Router.init([]))

    assert prompt_conn.status == 200

    wait_until(fn ->
      with {:ok, request} <- Store.get_request(key, "req-http-1") do
        request.status == "completed"
      else
        _ -> false
      end
    end)

    events_conn =
      conn(:get, "/v1/sessions/#{key}/events?after_seq=0&limit=100")
      |> put_req_header("authorization", "Bearer test-token")
      |> Router.call(Router.init([]))

    assert events_conn.status == 200
    %{"events" => events} = Jason.decode!(events_conn.resp_body)
    kinds = Enum.map(events, & &1["kind"])
    assert "prompt_completed" in kinds

    attach_body = Jason.encode!(%{"after_seq" => 0, "limit" => 100})

    attach_conn =
      conn(:post, "/v1/sessions/#{key}/attach", attach_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer test-token")
      |> Router.call(Router.init([]))

    assert attach_conn.status == 200

    %{"events" => attach_events, "session" => attach_session} =
      Jason.decode!(attach_conn.resp_body)

    assert Enum.any?(attach_events, &(&1["kind"] == "prompt_completed"))
    assert attach_session["gateway_session_key"] == key

    close_conn =
      conn(:delete, "/v1/sessions/#{key}")
      |> put_req_header("authorization", "Bearer test-token")
      |> Router.call(Router.init([]))

    assert close_conn.status == 200
    assert Jason.decode!(close_conn.resp_body)["closed"] == true
  end

  test "rejects unauthorized requests" do
    conn = conn(:get, "/v1/sessions/foo") |> Router.call(Router.init([]))
    assert conn.status == 401
  end

  defp wait_until(fun, attempts \\ 80)

  defp wait_until(_fun, 0), do: flunk("condition was not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end
end
