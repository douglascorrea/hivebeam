defmodule Hivebeam.Gateway.SLOTest do
  use ExUnit.Case, async: false

  alias Hivebeam.Gateway.SLO

  setup do
    case Process.whereis(SLO) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end

    start_supervised!({SLO, []})
    :ok
  end

  test "records session creation latency samples" do
    assert :ok = SLO.record_session_create_duration(45)
    assert :ok = SLO.record_session_create_duration(120)

    wait_until(fn ->
      snapshot = SLO.snapshot()
      length(snapshot.session_create_samples) == 2
    end)

    snapshot = SLO.snapshot()
    assert Enum.sort(snapshot.session_create_samples) == [45, 120]
  end

  test "tracks worker crash counts separately from normal exits" do
    assert :ok = SLO.record_worker_exit(:normal)
    assert :ok = SLO.record_worker_exit({:shutdown, :normal})
    assert :ok = SLO.record_worker_exit(:badarg)

    wait_until(fn ->
      snapshot = SLO.snapshot()
      snapshot.worker_exits == 3
    end)

    snapshot = SLO.snapshot()
    assert snapshot.worker_exits == 3
    assert snapshot.worker_crashes == 1
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(_fun, 0), do: flunk("condition was not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
