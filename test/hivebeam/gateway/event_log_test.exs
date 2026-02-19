defmodule Hivebeam.Gateway.EventLogTest do
  use ExUnit.Case, async: false

  alias Hivebeam.Gateway.EventLog
  alias Hivebeam.Gateway.Store

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "hivebeam_gateway_eventlog_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)

    pid = start_supervised!({Store, [data_dir: data_dir, max_events_per_session: 100]})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(data_dir)
    end)

    session = %{
      gateway_session_key: "hbs_ev",
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
    }

    {:ok, _} = Store.upsert_session(session)

    :ok
  end

  test "append and replay use the durable store contract" do
    assert {:ok, %{seq: 1}} = EventLog.append("hbs_ev", "session_created", "gateway", %{})

    assert {:ok, %{seq: 2}} =
             EventLog.append("hbs_ev", "stream_update", "upstream", %{text: "hello"})

    assert {:ok, replay} = EventLog.replay("hbs_ev", 0, 10)
    assert Enum.map(replay.events, & &1.seq) == [1, 2]

    assert :ok = EventLog.prune("hbs_ev")
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end
end
