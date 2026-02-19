defmodule Hivebeam.ClaudeTest do
  use ExUnit.Case, async: false

  alias Hivebeam.Claude

  defmodule FakeClaudeBridge do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, %{}, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:prompt, prompt, _opts}, _from, state) do
      {:reply, {:ok, %{session_id: "claude-local", stop_reason: "done", message_chunks: [prompt]}}, state}
    end

    def handle_call(:status, _from, state) do
      {:reply, {:ok, %{status: :connected, connected: true, session_id: "claude-local"}}, state}
    end

    def handle_call(:cancel_prompt, _from, state) do
      {:reply, :ok, state}
    end
  end

  setup do
    name = :"claude_test_bridge_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({FakeClaudeBridge, name: name})
    {:ok, pid: pid, name: name}
  end

  test "local prompt/status/cancel delegate to ClaudeBridge", %{name: name} do
    assert {:ok, result} = Claude.prompt("hello", bridge_name: name, timeout: 500)
    assert result.session_id == "claude-local"
    assert result.message_chunks == ["hello"]

    assert {:ok, status} = Claude.status(nil, bridge_name: name)
    assert status.connected == true

    assert :ok = Claude.cancel(nil, bridge_name: name)
  end

  test "Node.self target path reuses local flow", %{name: name} do
    assert {:ok, result} = Claude.prompt(Node.self(), "self-node", bridge_name: name, timeout: 500)
    assert result.message_chunks == ["self-node"]

    assert {:ok, status} = Claude.status(Node.self(), bridge_name: name)
    assert status.session_id == "claude-local"

    assert :ok = Claude.cancel(Node.self(), bridge_name: name)
  end
end
