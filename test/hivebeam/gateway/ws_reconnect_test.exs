defmodule Hivebeam.Gateway.WsReconnectTest do
  use ExUnit.Case, async: false

  alias Hivebeam.Gateway.EventLog
  alias Hivebeam.Gateway.Store

  setup do
    data_dir = Path.join(System.tmp_dir!(), "hivebeam_gateway_ws_#{System.unique_integer([:positive])}")
    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)

    start_supervised!({Store, [data_dir: data_dir, max_events_per_session: 200]})

    session = %{
      gateway_session_key: "hbs_ws_reconnect",
      provider: "codex",
      cwd: File.cwd!(),
      approval_mode: :ask,
      status: "connected",
      connected: true,
      in_flight: false,
      upstream_session_id: "s1",
      created_at: now_iso(),
      updated_at: now_iso(),
      last_seq: 0
    }

    {:ok, _} = Store.upsert_session(session)

    on_exit(fn -> File.rm_rf!(data_dir) end)

    :ok
  end

  test "replay after a cursor returns only missed events" do
    assert {:ok, %{seq: 1}} = EventLog.append("hbs_ws_reconnect", "stream_start", "upstream", %{})
    assert {:ok, %{seq: 2}} = EventLog.append("hbs_ws_reconnect", "stream_update", "upstream", %{text: "a"})
    assert {:ok, %{seq: 3}} = EventLog.append("hbs_ws_reconnect", "stream_done", "upstream", %{})

    assert {:ok, replay1} = Store.read_events("hbs_ws_reconnect", 0, 10)
    assert Enum.map(replay1.events, & &1.seq) == [1, 2, 3]

    last_seq = replay1.next_after_seq

    assert {:ok, %{seq: 4}} = EventLog.append("hbs_ws_reconnect", "prompt_started", "gateway", %{request_id: "r2"})
    assert {:ok, %{seq: 5}} = EventLog.append("hbs_ws_reconnect", "prompt_completed", "gateway", %{request_id: "r2"})

    assert {:ok, replay2} = Store.read_events("hbs_ws_reconnect", last_seq, 10)
    assert Enum.map(replay2.events, & &1.seq) == [4, 5]
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end
end
