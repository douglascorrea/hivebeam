defmodule Hivebeam.Test.FakeAcpStore do
  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn -> %{bridge: nil, calls: [], connections: [], prompt_task_pid: nil} end,
      name: __MODULE__
    )
  end

  def stop do
    if pid = Process.whereis(__MODULE__) do
      try do
        Agent.stop(pid)
      catch
        :exit, _ -> :ok
      end
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

defmodule Hivebeam.Test.FakeACPex do
  def start_client(_handler_module, handler_args, _opts) do
    bridge = Keyword.fetch!(handler_args, :bridge)
    Hivebeam.Test.FakeAcpStore.put_bridge(bridge)

    conn_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Hivebeam.Test.FakeAcpStore.add_connection(conn_pid)
    {:ok, conn_pid}
  end
end

defmodule Hivebeam.Test.FakeConnection do
  def send_request(_conn_pid, "initialize", params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({:initialize, params})
    %{"result" => %{"protocolVersion" => 1}}
  end

  def send_request(_conn_pid, "session/new", params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({:session_new, params})

    %{
      "result" => %{
        "sessionId" => "session-test",
        "modes" => %{
          "availableModes" => [
            %{"id" => "read-only"},
            %{"id" => "auto"},
            %{"id" => "full-access"}
          ]
        }
      }
    }
  end

  def send_request(_conn_pid, "session/set_mode", params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({:session_set_mode, params})
    %{"result" => %{}}
  end

  def send_request(_conn_pid, "session/prompt", params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({:session_prompt, params})

    if bridge = Hivebeam.Test.FakeAcpStore.bridge() do
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
    Hivebeam.Test.FakeAcpStore.add_call({method, params})
    %{"error" => %{"code" => -32000, "message" => "unexpected method"}}
  end

  def send_notification(_conn_pid, method, params) do
    Hivebeam.Test.FakeAcpStore.add_call({method, params})
    :ok
  end
end

defmodule Hivebeam.Test.FakeBlockingConnection do
  def send_request(_conn_pid, "initialize", params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({:initialize, params})
    %{"result" => %{"protocolVersion" => 1}}
  end

  def send_request(_conn_pid, "session/new", params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({:session_new, params})

    %{
      "result" => %{
        "sessionId" => "session-test",
        "modes" => %{
          "availableModes" => [
            %{"id" => "read-only"},
            %{"id" => "auto"},
            %{"id" => "full-access"}
          ]
        }
      }
    }
  end

  def send_request(_conn_pid, "session/set_mode", params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({:session_set_mode, params})
    %{"result" => %{}}
  end

  def send_request(_conn_pid, "session/prompt", params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({:session_prompt, params})
    Hivebeam.Test.FakeAcpStore.set_prompt_task_pid(self())

    receive do
      :continue_prompt -> :ok
    after
      5_000 -> :ok
    end

    %{"result" => %{"stopReason" => "end_turn"}}
  end

  def send_notification(_conn_pid, "session/cancel", params) do
    Hivebeam.Test.FakeAcpStore.add_call({:session_cancel, params})

    if prompt_task_pid = Hivebeam.Test.FakeAcpStore.prompt_task_pid() do
      send(prompt_task_pid, :continue_prompt)
    end

    :ok
  end

  def send_notification(_conn_pid, method, params) do
    Hivebeam.Test.FakeAcpStore.add_call({method, params})
    :ok
  end
end

defmodule Hivebeam.Test.FakeModeApplyErrorConnection do
  def send_request(_conn_pid, "initialize", params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({:initialize, params})
    %{"result" => %{"protocolVersion" => 1}}
  end

  def send_request(_conn_pid, "session/new", params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({:session_new, params})

    %{
      "result" => %{
        "sessionId" => "session-test",
        "modes" => %{
          "availableModes" => [
            %{"id" => "read-only"},
            %{"id" => "auto"},
            %{"id" => "full-access"}
          ]
        }
      }
    }
  end

  def send_request(_conn_pid, "session/set_mode", params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({:session_set_mode, params})
    %{"error" => %{"code" => -32000, "message" => "mode apply failed"}}
  end

  def send_request(_conn_pid, method, params, _timeout) do
    Hivebeam.Test.FakeAcpStore.add_call({method, params})
    %{"error" => %{"code" => -32000, "message" => "unexpected method"}}
  end

  def send_notification(_conn_pid, method, params) do
    Hivebeam.Test.FakeAcpStore.add_call({method, params})
    :ok
  end
end

defmodule Hivebeam.CodexBridgeTest do
  use ExUnit.Case, async: false

  alias Hivebeam.CodexBridge

  setup do
    {:ok, _pid} = Hivebeam.Test.FakeAcpStore.start_link([])

    on_exit(fn ->
      Hivebeam.Test.FakeAcpStore.stop()
    end)

    :ok
  end

  test "connects with read-only enforcement and reports connected status" do
    bridge_name = :"codex_bridge_#{System.unique_integer([:positive])}"
    tool_cwd = Path.join(System.tmp_dir!(), "hivebeam_codex_bridge_tool_cwd")

    File.mkdir_p!(tool_cwd)

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeACPex,
        connection_module: Hivebeam.Test.FakeConnection,
        config: %{acp_command: {"fake-acp", []}, reconnect_ms: 20, tool_cwd: tool_cwd}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.connected
    end)

    {:ok, status} = CodexBridge.status(bridge_name)
    assert status.status == :connected
    assert status.session_id == "session-test"
    assert status.enforced_provider_mode == "read-only"

    assert {:initialize, initialize_payload} =
             Enum.find(Hivebeam.Test.FakeAcpStore.calls(), fn {kind, _} ->
               kind == :initialize
             end)

    assert get_in(initialize_payload, ["clientCapabilities", "fs", "readTextFile"]) == true
    assert get_in(initialize_payload, ["clientCapabilities", "terminal"]) == true

    assert {:session_new, session_new_payload} =
             Enum.find(Hivebeam.Test.FakeAcpStore.calls(), fn
               {:session_new, _params} -> true
               _ -> false
             end)

    assert session_new_payload["cwd"] == tool_cwd

    assert {:session_set_mode, %{"modeId" => "read-only"}} =
             Enum.find(Hivebeam.Test.FakeAcpStore.calls(), fn
               {:session_set_mode, _params} -> true
               _ -> false
             end)
  end

  test "enforces full-access mode when approval mode is allow" do
    bridge_name = :"codex_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeACPex,
        connection_module: Hivebeam.Test.FakeConnection,
        config: %{acp_command: {"fake-acp", []}, reconnect_ms: 20, approval_mode: :allow}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.connected
    end)

    {:ok, status} = CodexBridge.status(bridge_name)
    assert status.enforced_provider_mode == "full-access"

    assert {:session_set_mode, %{"modeId" => "full-access"}} =
             Enum.find(Hivebeam.Test.FakeAcpStore.calls(), fn
               {:session_set_mode, _params} -> true
               _ -> false
             end)
  end

  test "degrades bridge when provider mode enforcement fails" do
    bridge_name = :"codex_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeACPex,
        connection_module: Hivebeam.Test.FakeModeApplyErrorConnection,
        config: %{acp_command: {"fake-acp", []}, reconnect_ms: 20}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.status == :degraded
    end)

    {:ok, status} = CodexBridge.status(bridge_name)
    refute status.connected

    assert {:mode_enforcement_failed, %{"message" => "mode apply failed"}} = status.last_error
  end

  test "collects prompt updates, streams updates, and normalizes stop reason" do
    bridge_name = :"codex_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeACPex,
        connection_module: Hivebeam.Test.FakeConnection,
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
        acpex_module: Hivebeam.Test.FakeACPex,
        connection_module: Hivebeam.Test.FakeBlockingConnection,
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
      status.in_flight_prompt and is_pid(Hivebeam.Test.FakeAcpStore.prompt_task_pid())
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

    send(Hivebeam.Test.FakeAcpStore.prompt_task_pid(), :continue_prompt)
    assert {:ok, _result} = Task.await(prompt_task)
  end

  test "cancel_prompt sends session/cancel and unblocks in-flight prompt" do
    bridge_name = :"codex_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeACPex,
        connection_module: Hivebeam.Test.FakeBlockingConnection,
        config: %{acp_command: {"fake-acp", []}, reconnect_ms: 20}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.connected
    end)

    prompt_task =
      Task.async(fn ->
        CodexBridge.prompt("long running prompt",
          bridge_name: bridge_name,
          timeout: 5_000,
          stream_to: self()
        )
      end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.in_flight_prompt and is_pid(Hivebeam.Test.FakeAcpStore.prompt_task_pid())
    end)

    assert :ok = CodexBridge.cancel_prompt(bridge_name: bridge_name)
    assert {:ok, _result} = Task.await(prompt_task)

    assert {:session_cancel, %{"sessionId" => "session-test"}} =
             Enum.find(Hivebeam.Test.FakeAcpStore.calls(), fn
               {:session_cancel, _params} -> true
               _ -> false
             end)
  end

  test "cancel_prompt returns error when no prompt is running" do
    bridge_name = :"codex_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeACPex,
        connection_module: Hivebeam.Test.FakeConnection,
        config: %{acp_command: {"fake-acp", []}, reconnect_ms: 20}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = CodexBridge.status(bridge_name)
      status.connected
    end)

    assert {:error, :no_prompt_in_progress} = CodexBridge.cancel_prompt(bridge_name: bridge_name)
  end

  test "reconnects after connection process dies" do
    bridge_name = :"codex_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      CodexBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeACPex,
        connection_module: Hivebeam.Test.FakeConnection,
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
    try do
      GenServer.stop(pid)
    rescue
      _ -> :ok
    catch
      :exit, _reason -> :ok
    end
  end
end
