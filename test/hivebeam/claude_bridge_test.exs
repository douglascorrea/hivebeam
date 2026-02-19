defmodule Hivebeam.Test.FakeClaudeAcpStore do
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

defmodule Hivebeam.Test.FakeClaudeClientModule do
  def start_client(_handler_module, handler_args, _opts) do
    bridge = Keyword.fetch!(handler_args, :bridge)
    Hivebeam.Test.FakeClaudeAcpStore.put_bridge(bridge)

    conn_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Hivebeam.Test.FakeClaudeAcpStore.add_connection(conn_pid)
    {:ok, conn_pid}
  end
end

defmodule Hivebeam.Test.FakeClaudeConnection do
  def send_request(_conn_pid, "initialize", params, _timeout) do
    Hivebeam.Test.FakeClaudeAcpStore.add_call({:initialize, params})
    %{"result" => %{"protocolVersion" => 1}}
  end

  def send_request(_conn_pid, "session/new", params, _timeout) do
    Hivebeam.Test.FakeClaudeAcpStore.add_call({:session_new, params})

    %{
      "result" => %{
        "sessionId" => "claude-session-test",
        "modes" => %{
          "availableModes" => [
            %{"id" => "default"},
            %{"id" => "acceptEdits"},
            %{"id" => "dontAsk"},
            %{"id" => "bypassPermissions"},
            %{"id" => "plan"}
          ]
        }
      }
    }
  end

  def send_request(_conn_pid, "session/set_mode", params, _timeout) do
    Hivebeam.Test.FakeClaudeAcpStore.add_call({:session_set_mode, params})
    %{"result" => %{}}
  end

  def send_request(_conn_pid, "session/prompt", params, _timeout) do
    Hivebeam.Test.FakeClaudeAcpStore.add_call({:session_prompt, params})

    if bridge = Hivebeam.Test.FakeClaudeAcpStore.bridge() do
      send(
        bridge,
        {:acp_session_update,
         %{
           session_id: "claude-session-test",
           update: %{"type" => "agent_thought_chunk", "content" => %{"text" => "c1"}}
         }}
      )

      send(
        bridge,
        {:acp_session_update,
         %{
           session_id: "claude-session-test",
           update: %{"type" => "agent_message_chunk", "content" => %{"text" => "CLAUDE_OK"}}
         }}
      )
    end

    %{"result" => %{"stopReason" => "end_turn"}}
  end

  def send_request(_conn_pid, method, params, _timeout) do
    Hivebeam.Test.FakeClaudeAcpStore.add_call({method, params})
    %{"error" => %{"code" => -32000, "message" => "unexpected method"}}
  end

  def send_notification(_conn_pid, method, params) do
    Hivebeam.Test.FakeClaudeAcpStore.add_call({method, params})
    :ok
  end
end

defmodule Hivebeam.Test.FakeClaudeModeUnavailableConnection do
  def send_request(_conn_pid, "initialize", params, _timeout) do
    Hivebeam.Test.FakeClaudeAcpStore.add_call({:initialize, params})
    %{"result" => %{"protocolVersion" => 1}}
  end

  def send_request(_conn_pid, "session/new", params, _timeout) do
    Hivebeam.Test.FakeClaudeAcpStore.add_call({:session_new, params})

    %{
      "result" => %{
        "sessionId" => "claude-session-test",
        "modes" => %{
          "availableModes" => [
            %{"id" => "default"},
            %{"id" => "acceptEdits"},
            %{"id" => "dontAsk"},
            %{"id" => "plan"}
          ]
        }
      }
    }
  end

  def send_request(_conn_pid, "session/set_mode", params, _timeout) do
    Hivebeam.Test.FakeClaudeAcpStore.add_call({:session_set_mode, params})
    %{"result" => %{}}
  end

  def send_request(_conn_pid, method, params, _timeout) do
    Hivebeam.Test.FakeClaudeAcpStore.add_call({method, params})
    %{"error" => %{"code" => -32000, "message" => "unexpected method"}}
  end

  def send_notification(_conn_pid, method, params) do
    Hivebeam.Test.FakeClaudeAcpStore.add_call({method, params})
    :ok
  end
end

defmodule Hivebeam.ClaudeBridgeTest do
  use ExUnit.Case, async: false

  alias Hivebeam.ClaudeBridge

  setup do
    {:ok, _pid} = Hivebeam.Test.FakeClaudeAcpStore.start_link([])

    on_exit(fn ->
      Hivebeam.Test.FakeClaudeAcpStore.stop()
    end)

    :ok
  end

  test "connects with claude defaults, project settings source, and mode enforcement" do
    bridge_name = :"claude_bridge_#{System.unique_integer([:positive])}"
    tool_cwd = Path.join(System.tmp_dir!(), "hivebeam_claude_bridge_tool_cwd")

    File.mkdir_p!(tool_cwd)

    {:ok, bridge_pid} =
      ClaudeBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeClaudeClientModule,
        connection_module: Hivebeam.Test.FakeClaudeConnection,
        config: %{acp_command: {"fake-claude-acp", []}, reconnect_ms: 20, tool_cwd: tool_cwd}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = ClaudeBridge.status(bridge_name)
      status.connected
    end)

    {:ok, status} = ClaudeBridge.status(bridge_name)
    assert status.status == :connected
    assert status.acp_provider == "claude"
    assert status.session_id == "claude-session-test"
    assert status.enforced_provider_mode == "default"

    assert {:initialize, initialize_payload} =
             Enum.find(Hivebeam.Test.FakeClaudeAcpStore.calls(), fn {kind, _} ->
               kind == :initialize
             end)

    assert get_in(initialize_payload, ["clientCapabilities", "fs", "readTextFile"]) == true

    assert {:session_new, session_new_payload} =
             Enum.find(Hivebeam.Test.FakeClaudeAcpStore.calls(), fn
               {:session_new, _params} -> true
               _ -> false
             end)

    assert session_new_payload["cwd"] == tool_cwd

    assert get_in(session_new_payload, ["_meta", "claudeCode", "options", "settingSources"]) == [
             "project"
           ]

    assert {:session_set_mode, %{"modeId" => "default"}} =
             Enum.find(Hivebeam.Test.FakeClaudeAcpStore.calls(), fn
               {:session_set_mode, _params} -> true
               _ -> false
             end)
  end

  test "enforces dontAsk mode when approval mode is deny" do
    bridge_name = :"claude_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      ClaudeBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeClaudeClientModule,
        connection_module: Hivebeam.Test.FakeClaudeConnection,
        config: %{acp_command: {"fake-claude-acp", []}, reconnect_ms: 20, approval_mode: :deny}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = ClaudeBridge.status(bridge_name)
      status.connected
    end)

    {:ok, status} = ClaudeBridge.status(bridge_name)
    assert status.enforced_provider_mode == "dontAsk"

    assert {:session_set_mode, %{"modeId" => "dontAsk"}} =
             Enum.find(Hivebeam.Test.FakeClaudeAcpStore.calls(), fn
               {:session_set_mode, _params} -> true
               _ -> false
             end)
  end

  test "enforces bypassPermissions mode when approval mode is allow" do
    bridge_name = :"claude_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      ClaudeBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeClaudeClientModule,
        connection_module: Hivebeam.Test.FakeClaudeConnection,
        config: %{acp_command: {"fake-claude-acp", []}, reconnect_ms: 20, approval_mode: :allow}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = ClaudeBridge.status(bridge_name)
      status.connected
    end)

    {:ok, status} = ClaudeBridge.status(bridge_name)
    assert status.enforced_provider_mode == "bypassPermissions"

    assert {:session_set_mode, %{"modeId" => "bypassPermissions"}} =
             Enum.find(Hivebeam.Test.FakeClaudeAcpStore.calls(), fn
               {:session_set_mode, _params} -> true
               _ -> false
             end)
  end

  test "degrades bridge when required mode is unavailable" do
    bridge_name = :"claude_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      ClaudeBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeClaudeClientModule,
        connection_module: Hivebeam.Test.FakeClaudeModeUnavailableConnection,
        config: %{acp_command: {"fake-claude-acp", []}, reconnect_ms: 20, approval_mode: :allow}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = ClaudeBridge.status(bridge_name)
      status.status == :degraded
    end)

    {:ok, status} = ClaudeBridge.status(bridge_name)
    refute status.connected
    assert {:mode_unavailable, "bypassPermissions", _available_modes} = status.last_error
  end

  test "collects prompt updates and normalizes stop reason" do
    bridge_name = :"claude_bridge_#{System.unique_integer([:positive])}"

    {:ok, bridge_pid} =
      ClaudeBridge.start_link(
        name: bridge_name,
        acpex_module: Hivebeam.Test.FakeClaudeClientModule,
        connection_module: Hivebeam.Test.FakeClaudeConnection,
        config: %{acp_command: {"fake-claude-acp", []}, reconnect_ms: 20}
      )

    on_exit(fn -> safe_stop(bridge_pid) end)

    wait_until(fn ->
      {:ok, status} = ClaudeBridge.status(bridge_name)
      status.connected
    end)

    assert {:ok, result} =
             ClaudeBridge.prompt("reply please",
               bridge_name: bridge_name,
               timeout: 500,
               stream_to: self(),
               approval_to: self()
             )

    assert result.stop_reason == "done"
    assert result.raw_stop_reason == "end_turn"
    assert result.thought_chunks == ["c1"]
    assert result.message_chunks == ["CLAUDE_OK"]

    assert_receive {:codex_prompt_stream, %{event: :start}}, 200
    assert_receive {:codex_prompt_stream, %{event: :update}}, 200
    assert_receive {:codex_prompt_stream, %{event: :done}}, 200
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(_fun, 0), do: flunk("condition was not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp safe_stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end
end
