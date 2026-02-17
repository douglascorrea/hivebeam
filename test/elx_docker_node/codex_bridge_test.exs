defmodule ElxDockerNode.Test.FakeAcpStore do
  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn -> %{bridge: nil, calls: [], connections: [], prompt_task_pid: nil} end,
      name: __MODULE__
    )
  end

  def stop do
    if pid = Process.whereis(__MODULE__) do
      Agent.stop(pid)
    end
  end

  def put_bridge(bridge), do: Agent.update(__MODULE__, &Map.put(&1, :bridge, bridge))
  def bridge, do: Agent.get(__MODULE__, & &1.bridge)

  def add_call(call) do
    Agent.update(__MODULE__, fn state -> Map.update!(state, :calls, &[call | &1]) end)
  end

  def calls do
    Agent.get(__MODULE__, fn state -> Enum.reverse(state.calls) end)
  end

  def add_connection(conn_pid) do
    Agent.update(__MODULE__, fn state -> Map.update!(state, :connections, &[conn_pid | &1]) end)
  end

  def set_prompt_task_pid(pid) do
    Agent.update(__MODULE__, &Map.put(&1, :prompt_task_pid, pid))
  end

  def prompt_task_pid do
    Agent.get(__MODULE__, & &1.prompt_task_pid)
  end
end

defmodule ElxDockerNode.Test.FakeACPex do
  def start_client(_handler_module, handler_args, _opts) do
    bridge = Keyword.fetch!(handler_args, :bridge)
    ElxDockerNode.Test.FakeAcpStore.put_bridge(bridge)

    conn_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ElxDockerNode.Test.FakeAcpStore.add_connection(conn_pid)
    {:ok, conn_pid}
  end
end

defmodule ElxDockerNode.Test.FakeConnection do
  def send_request(_conn_pid, "initialize", params, _timeout) do
    ElxDockerNode.Test.FakeAcpStore.add_call({:initialize, params})
    %{"result" => %{"protocolVersion" => 1}}
  end

  def send_request(_conn_pid, "session/new", params, _timeout) do
    ElxDockerNode.Test.FakeAcpStore.add_call({:session_new, params})
    %{"result" => %{"sessionId" => "session-test"}}
  end

  def send_request(_conn_pid, "session/prompt", params, _timeout) do
    ElxDockerNode.Test.FakeAcpStore.add_call({:session_prompt, params})

    if bridge = ElxDockerNode.Test.FakeAcpStore.bridge() do
      send(
        bridge,
        {:acp_session_update,
         %{
           session_id: "session-test",
           update: %{"type" => "agent_thought_chunk", "content" => %{"text" => "h1"}}
         }}
      )

      send(
        bridge,
        {:acp_session_update,
         %{
           session_id: "session-test",
           update: %{"type" => "agent_message_chunk", "content" => %{"text" => "ACP_OK"}}
         }}
      )

      send(
        bridge,
        {:acp_session_update,
         %{
           session_id: "session-test",
           update: %{"type" => "tool_call", "title" => "Edit file", "status" => "completed"}
         }}
      )
    end

    %{"result" => %{"stopReason" => "end_turn"}}
  end

  def send_request(_conn_pid, method, params, _timeout) do
    ElxDockerNode.Test.FakeAcpStore.add_call({method, params})
    %{"error" => %{"code" => -32000, "message" => "unexpected method"}}
  end
end

defmodule ElxDockerNode.Test.FakeBlockingConnection do
  def send_request(_conn_pid, "initialize", params, _timeout) do
    ElxDockerNode.Test.FakeAcpStore.add_call({:initialize, params})
    %{"result" => %{"protocolVersion" => 1}}
  end

  def send_request(_conn_pid, "session/new", params, _timeout) do
    ElxDockerNode.Test.FakeAcpStore.add_call({:session_new, params})
    %{"result" => %{"sessionId" => "session-test"}}
  end

  def send_request(_conn_pid, "session/prompt", params, _timeout) do
    ElxDockerNode.Test.FakeAcpStore.add_call({:session_prompt, params})
    ElxDockerNode.Test.FakeAcpStore.set_prompt_task_pid(self())

    receive do
      :continue_prompt -> :ok
    after
      5_000 -> :ok
    end

    %{"result" => %{"stopReason" => "end_turn"}}
  end
end

defmodule ElxDockerNode.CodexBridgeTest do
  use ExUnit.Case, async: false

  alias ElxDockerNode.CodexBridge

  setup do
    {:ok, _pid} = ElxDockerNode.Test.FakeAcpStore.start_link([])

    on_exit(fn ->
      ElxDockerNode.Test.FakeAcpStore.stop()
    end)

    :ok
  end

  test "connects and reports connected status" do
    bridge_name = :"codex_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        acpex_module: ElxDockerNode.Test.FakeACPex,
        connection_module: ElxDockerNode.Test.FakeConnection,
        config: %{acp_command: {"fake-acp", []}, reconnect_ms: 20}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.connected
    end)

    {:ok, status} = CodexBridge.status(bridge_name)
    assert status.status == :connected
    assert status.session_id == "session-test"

    assert {:initialize, initialize_payload} =
             Enum.find(ElxDockerNode.Test.FakeAcpStore.calls(), fn {kind, _} ->
               kind == :initialize
             end)

    assert get_in(initialize_payload, ["clientCapabilities", "fs", "readTextFile"]) == true
    assert get_in(initialize_payload, ["clientCapabilities", "terminal"]) == true
  end

  test "collects prompt updates, streams updates, and normalizes stop reason" do
    bridge_name = :"codex_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        acpex_module: ElxDockerNode.Test.FakeACPex,
        connection_module: ElxDockerNode.Test.FakeConnection,
        config: %{acp_command: {"fake-acp", []}, reconnect_ms: 20}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.connected
    end)

    assert {:ok, result} =
             CodexBridge.prompt("reply please",
               bridge_name: bridge_name,
               timeout: 500,
               stream_to: self(),
               approval_to: self()
             )

    assert result.stop_reason == "done"
    assert result.raw_stop_reason == "end_turn"
    assert result.thought_chunks == ["h1"]
    assert result.message_chunks == ["ACP_OK"]
    assert length(result.tool_events) == 1

    assert_receive {:codex_prompt_stream, %{event: :start}}, 200

    assert_receive {:codex_prompt_stream,
                    %{event: :update, update: %{"type" => "agent_thought_chunk"}}},
                   200

    assert_receive {:codex_prompt_stream, %{event: :done}}, 200
  end

  test "routes tool approvals to the prompt approval process" do
    bridge_name = :"codex_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        acpex_module: ElxDockerNode.Test.FakeACPex,
        connection_module: ElxDockerNode.Test.FakeBlockingConnection,
        config: %{acp_command: {"fake-acp", []}, reconnect_ms: 20}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.connected
    end)

    parent = self()

    prompt_task =
      Task.async(fn ->
        CodexBridge.prompt("wait for approval",
          bridge_name: bridge_name,
          timeout: 5_000,
          approval_to: parent,
          stream_to: parent
        )
      end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.in_flight_prompt and is_pid(ElxDockerNode.Test.FakeAcpStore.prompt_task_pid())
    end)

    approval_task =
      Task.async(fn ->
        CodexBridge.request_tool_approval(
          %{"operation" => "terminal/create", "details" => %{"command" => "echo"}},
          bridge_name: bridge_name,
          timeout: 2_000
        )
      end)

    assert_receive {:codex_tool_approval_request, %{ref: ref, reply_to: reply_to}}, 500
    send(reply_to, {:codex_tool_approval_reply, ref, true})

    assert {:ok, true} = Task.await(approval_task)

    send(ElxDockerNode.Test.FakeAcpStore.prompt_task_pid(), :continue_prompt)
    assert {:ok, _result} = Task.await(prompt_task)
  end

  test "reconnects after connection process dies" do
    bridge_name = :"codex_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        acpex_module: ElxDockerNode.Test.FakeACPex,
        connection_module: ElxDockerNode.Test.FakeConnection,
        config: %{acp_command: {"fake-acp", []}, reconnect_ms: 20}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.connected and is_pid(status.connection_pid)
    end)

    {:ok, before_status} = CodexBridge.status(bridge_name)
    Process.exit(before_status.connection_pid, :kill)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)

      status.connected and is_pid(status.connection_pid) and
        status.connection_pid != before_status.connection_pid
    end)
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

  defp safe_stop(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end
  end
end
