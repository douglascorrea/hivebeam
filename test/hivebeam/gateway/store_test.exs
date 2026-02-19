defmodule Hivebeam.Gateway.StoreTest do
  use ExUnit.Case, async: false

  alias Hivebeam.Gateway.Store

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "hivebeam_gateway_store_#{System.unique_integer([:positive])}")

    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)

    pid = start_supervised!({Store, [data_dir: data_dir, max_events_per_session: 3]})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(data_dir)
    end)

    {:ok, data_dir: data_dir}
  end

  test "persists session and replays ordered events" do
    session = %{
      gateway_session_key: "hbs_test_a",
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

    assert {:ok, _} = Store.upsert_session(session)

    assert {:ok, %{seq: 1}} = Store.append_event("hbs_test_a", "session_created", "gateway", %{})
    assert {:ok, %{seq: 2}} = Store.append_event("hbs_test_a", "stream_start", "upstream", %{})
    assert {:ok, %{seq: 3}} = Store.append_event("hbs_test_a", "stream_done", "upstream", %{})

    assert {:ok, replay} = Store.read_events("hbs_test_a", 1, 10)
    assert Enum.map(replay.events, & &1.seq) == [2, 3]
    assert replay.has_more == false
    assert replay.next_after_seq == 3
  end

  test "tracks request idempotency records" do
    session = %{
      gateway_session_key: "hbs_test_b",
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

    assert {:ok, _} = Store.upsert_session(session)

    assert {:ok, request} =
             Store.put_request("hbs_test_b", "req-1", %{status: "queued", text: "hello"})

    assert request.status == "queued"

    assert {:ok, updated} =
             Store.update_request("hbs_test_b", "req-1", %{
               status: "completed",
               result: %{ok: true}
             })

    assert updated.status == "completed"

    assert {:ok, fetched} = Store.get_request("hbs_test_b", "req-1")
    assert fetched.result == %{ok: true}
  end

  test "prunes old events when max_events_per_session is exceeded" do
    session = %{
      gateway_session_key: "hbs_test_c",
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

    assert {:ok, _} = Store.upsert_session(session)

    for seq <- 1..8 do
      assert {:ok, %{seq: ^seq}} =
               Store.append_event("hbs_test_c", "event_#{seq}", "gateway", %{})
    end

    assert :ok = Store.prune_session_events("hbs_test_c")

    assert {:ok, replay} = Store.read_events("hbs_test_c", 0, 20)
    assert Enum.map(replay.events, & &1.seq) == [6, 7, 8]
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end
end
