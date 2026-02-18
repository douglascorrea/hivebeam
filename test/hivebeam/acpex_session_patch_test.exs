defmodule Hivebeam.ACPexSessionPatchTest do
  use ExUnit.Case, async: true

  alias ACPex.Protocol.Session

  defmodule HandlerWithInfo do
    def handle_info(message, state) do
      send(state.owner, {:handler_info, message})
      {:noreply, Map.put(state, :seen, true)}
    end
  end

  defmodule HandlerWithoutInfo do
  end

  test "session forwards async messages to handler handle_info/2 when implemented" do
    {:ok, session_pid} =
      Session.start_link(%{
        handler_module: HandlerWithInfo,
        initial_handler_state: %{owner: self()},
        transport_pid: self(),
        session_id: "test-session"
      })

    ref = make_ref()
    send(session_pid, {:DOWN, ref, :process, self(), :normal})

    assert_receive {:handler_info, {:DOWN, ^ref, :process, _pid, :normal}}, 500
    assert Process.alive?(session_pid)
  end

  test "session ignores unknown async messages when handler has no handle_info/2" do
    {:ok, session_pid} =
      Session.start_link(%{
        handler_module: HandlerWithoutInfo,
        initial_handler_state: %{},
        transport_pid: self(),
        session_id: "test-session-noinfo"
      })

    send(session_pid, {:DOWN, make_ref(), :process, self(), :normal})
    Process.sleep(50)

    assert Process.alive?(session_pid)
  end
end
