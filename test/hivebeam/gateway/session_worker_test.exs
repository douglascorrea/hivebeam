defmodule Hivebeam.Gateway.SessionWorkerTest do
  use ExUnit.Case, async: false

  alias Hivebeam.Gateway.SessionWorker
  alias Hivebeam.Gateway.Store

  defmodule FakeBridge do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(_opts) do
      {:ok, %{session_id: "upstream-session", in_flight: false, cancelled: false}}
    end

    def status(server) do
      GenServer.call(server, :status)
    end

    def prompt(text, opts) do
      bridge_name = Keyword.fetch!(opts, :bridge_name)
      timeout = Keyword.get(opts, :timeout, 5_000)
      GenServer.call(bridge_name, {:prompt, text, opts}, timeout)
    end

    def cancel_prompt(opts) do
      bridge_name = Keyword.fetch!(opts, :bridge_name)
      GenServer.call(bridge_name, :cancel)
    end

    @impl true
    def handle_call(:status, _from, state) do
      {:reply,
       {:ok,
        %{
          status: :connected,
          connected: true,
          session_id: state.session_id,
          in_flight_prompt: state.in_flight,
          approval_mode: :ask,
          last_error: nil
        }}, state}
    end

    def handle_call(:cancel, _from, state) do
      {:reply, :ok, %{state | cancelled: true, in_flight: false}}
    end

    def handle_call({:prompt, text, opts}, _from, state) do
      stream_to = Keyword.fetch!(opts, :stream_to)
      approval_to = Keyword.fetch!(opts, :approval_to)

      send(
        stream_to,
        {:codex_prompt_stream, %{event: :start, update: %{"type" => "agent_message_chunk"}}}
      )

      cond do
        text == "needs approval" ->
          ref = make_ref()

          send(
            approval_to,
            {:codex_tool_approval_request,
             %{ref: ref, reply_to: self(), request: %{operation: "terminal/create"}}}
          )

          receive do
            {:codex_tool_approval_reply, ^ref, true} ->
              send(stream_to, {:codex_prompt_stream, %{event: :status, message: "approved"}})

            {:codex_tool_approval_reply, ^ref, false} ->
              send(stream_to, {:codex_prompt_stream, %{event: :status, message: "denied"}})
          after
            500 ->
              send(
                stream_to,
                {:codex_prompt_stream, %{event: :status, message: "approval_timeout"}}
              )
          end

        text == "blocked approval" ->
          ref = make_ref()

          send(
            approval_to,
            {:codex_tool_approval_request,
             %{
               ref: ref,
               reply_to: self(),
               request: %{operation: "fs/write_text_file", details: %{path: "/etc/hivebeam.txt"}}
             }}
          )

          receive do
            {:codex_tool_approval_reply, ^ref, true} ->
              send(
                stream_to,
                {:codex_prompt_stream, %{event: :status, message: "unexpected_allow"}}
              )

            {:codex_tool_approval_reply, ^ref, false} ->
              send(stream_to, {:codex_prompt_stream, %{event: :status, message: "auto_denied"}})
          after
            500 ->
              send(
                stream_to,
                {:codex_prompt_stream, %{event: :status, message: "approval_timeout"}}
              )
          end

        true ->
          send(
            stream_to,
            {:codex_prompt_stream,
             %{event: :update, update: %{"type" => "agent_message_chunk", "text" => "hello"}}}
          )
      end

      send(stream_to, {:codex_prompt_stream, %{event: :done}})

      {:reply,
       {:ok, %{session_id: state.session_id, stop_reason: "done", message_chunks: ["ACK"]}},
       %{state | in_flight: false}}
    end
  end

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "hivebeam_gateway_worker_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)

    start_supervised!({Registry, keys: :unique, name: Hivebeam.Gateway.WorkerRegistry})
    start_supervised!({Registry, keys: :duplicate, name: Hivebeam.Gateway.EventRegistry})
    start_supervised!({Store, [data_dir: data_dir, max_events_per_session: 100]})
    start_supervised!(Hivebeam.Gateway.SessionSupervisor)

    on_exit(fn ->
      Application.delete_env(:hivebeam, :gateway_bridge_modules)
      Application.delete_env(:hivebeam, :gateway_bridge_module)
      File.rm_rf!(data_dir)
    end)

    :ok
  end

  test "runs prompt queue and records completion events" do
    key = "hbs_worker_basic"

    assert {:ok, _session} =
             Store.upsert_session(%{
               gateway_session_key: key,
               provider: "codex",
               cwd: File.cwd!(),
               approval_mode: :ask,
               status: "creating",
               connected: false,
               in_flight: false,
               upstream_session_id: nil,
               created_at: now_iso(),
               updated_at: now_iso(),
               last_seq: 0
             })

    assert {:ok, worker} =
             SessionWorker.start_link(
               session_key: key,
               bridge_module: FakeBridge,
               recovered?: false
             )

    assert {:ok, %{accepted: true, request_id: "req-1"}} =
             GenServer.call(worker, {:prompt, "req-1", "hello", 2_000}, 5_000)

    wait_until(fn ->
      case Store.get_request(key, "req-1") do
        {:ok, %{status: "completed"}} -> true
        _ -> false
      end
    end)

    assert {:ok, replay} = Store.read_events(key, 0, 50)

    kinds = Enum.map(replay.events, & &1.kind)
    assert "prompt_started" in kinds
    assert "prompt_completed" in kinds
    assert "stream_start" in kinds
    assert "stream_done" in kinds
  end

  test "accepts approval decision for pending approval" do
    key = "hbs_worker_approval"

    assert {:ok, _session} =
             Store.upsert_session(%{
               gateway_session_key: key,
               provider: "codex",
               cwd: File.cwd!(),
               approval_mode: :ask,
               status: "creating",
               connected: false,
               in_flight: false,
               upstream_session_id: nil,
               created_at: now_iso(),
               updated_at: now_iso(),
               last_seq: 0
             })

    assert {:ok, worker} =
             SessionWorker.start_link(
               session_key: key,
               bridge_module: FakeBridge,
               recovered?: false
             )

    assert {:ok, %{accepted: true, request_id: "req-2"}} =
             GenServer.call(worker, {:prompt, "req-2", "needs approval", 2_000}, 5_000)

    approval_ref =
      wait_for_value(fn ->
        with {:ok, replay} <- Store.read_events(key, 0, 50),
             event when not is_nil(event) <-
               Enum.find(replay.events, &(&1.kind == "approval_requested")) do
          get_in(event, [:payload, "approval_ref"])
        else
          _ -> nil
        end
      end)

    assert is_binary(approval_ref)

    assert {:ok, %{accepted: true}} =
             GenServer.call(worker, {:approve, approval_ref, "allow"}, 5_000)

    wait_until(fn ->
      case Store.get_request(key, "req-2") do
        {:ok, %{status: "completed"}} -> true
        _ -> false
      end
    end)

    assert {:ok, replay} = Store.read_events(key, 0, 100)
    assert Enum.any?(replay.events, &(&1.kind == "approval_resolved"))
  end

  test "auto-denies sandbox-violating approval requests" do
    key = "hbs_worker_sandbox_deny"

    assert {:ok, _session} =
             Store.upsert_session(%{
               gateway_session_key: key,
               provider: "codex",
               cwd: File.cwd!(),
               sandbox_roots: [File.cwd!()],
               sandbox_default_root: File.cwd!(),
               dangerously: false,
               approval_mode: :ask,
               status: "creating",
               connected: false,
               in_flight: false,
               upstream_session_id: nil,
               created_at: now_iso(),
               updated_at: now_iso(),
               last_seq: 0
             })

    assert {:ok, worker} =
             SessionWorker.start_link(
               session_key: key,
               bridge_module: FakeBridge,
               recovered?: false
             )

    assert {:ok, %{accepted: true, request_id: "req-sandbox-1"}} =
             GenServer.call(worker, {:prompt, "req-sandbox-1", "blocked approval", 2_000}, 5_000)

    wait_until(fn ->
      case Store.get_request(key, "req-sandbox-1") do
        {:ok, %{status: "completed"}} -> true
        _ -> false
      end
    end)

    assert {:ok, replay} = Store.read_events(key, 0, 100)
    kinds = Enum.map(replay.events, & &1.kind)

    assert "approval_auto_denied" in kinds
    refute "approval_requested" in kinds
  end

  test "resolves provider-specific bridge module from gateway_bridge_modules map" do
    key = "hbs_worker_claude_provider"

    Application.put_env(:hivebeam, :gateway_bridge_modules, %{"claude" => FakeBridge})

    assert {:ok, _session} =
             Store.upsert_session(%{
               gateway_session_key: key,
               provider: "claude",
               cwd: File.cwd!(),
               approval_mode: :ask,
               status: "creating",
               connected: false,
               in_flight: false,
               upstream_session_id: nil,
               created_at: now_iso(),
               updated_at: now_iso(),
               last_seq: 0
             })

    assert {:ok, worker} = SessionWorker.start_link(session_key: key, recovered?: false)

    assert {:ok, %{accepted: true, request_id: "req-claude-1"}} =
             GenServer.call(worker, {:prompt, "req-claude-1", "hello", 2_000}, 5_000)

    wait_until(fn ->
      case Store.get_request(key, "req-claude-1") do
        {:ok, %{status: "completed"}} -> true
        _ -> false
      end
    end)

    assert {:ok, replay} = Store.read_events(key, 0, 50)
    assert Enum.any?(replay.events, &(&1.kind == "prompt_completed"))
  end

  test "does not respawn worker after close" do
    key = "hbs_worker_close_no_respawn"

    assert {:ok, _session} =
             Store.upsert_session(%{
               gateway_session_key: key,
               provider: "codex",
               cwd: File.cwd!(),
               approval_mode: :ask,
               status: "creating",
               connected: false,
               in_flight: false,
               upstream_session_id: nil,
               created_at: now_iso(),
               updated_at: now_iso(),
               last_seq: 0
             })

    assert {:ok, worker} =
             SessionWorker.start_link(
               session_key: key,
               bridge_module: FakeBridge,
               recovered?: false
             )

    ref = Process.monitor(worker)

    assert {:ok, %{closed: true}} = GenServer.call(worker, :close, 5_000)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000

    wait_until(fn ->
      Registry.lookup(Hivebeam.Gateway.WorkerRegistry, {:session_worker, key}) == []
    end)
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
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

  defp wait_for_value(fun, attempts \\ 80)

  defp wait_for_value(_fun, 0), do: flunk("value was not produced in time")

  defp wait_for_value(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(25)
        wait_for_value(fun, attempts - 1)

      value ->
        value
    end
  end
end
