defmodule Hivebeam.ApplicationGatewayBootTest do
  use ExUnit.Case, async: false

  alias Hivebeam.Application, as: HivebeamApplication

  setup do
    original_token = System.get_env("HIVEBEAM_GATEWAY_TOKEN")

    on_exit(fn ->
      case original_token do
        nil -> System.delete_env("HIVEBEAM_GATEWAY_TOKEN")
        value -> System.put_env("HIVEBEAM_GATEWAY_TOKEN", value)
      end
    end)

    :ok
  end

  test "boot fails without gateway token" do
    stop_supervisor_if_running()
    System.delete_env("HIVEBEAM_GATEWAY_TOKEN")

    assert_raise RuntimeError, ~r/HIVEBEAM_GATEWAY_TOKEN is required/, fn ->
      HivebeamApplication.start(:normal, [])
    end
  end

  test "boot succeeds with gateway token" do
    stop_supervisor_if_running()
    System.put_env("HIVEBEAM_GATEWAY_TOKEN", "boot-test-token")

    assert {:ok, pid} = HivebeamApplication.start(:normal, [])
    assert Process.alive?(pid)

    assert :ok = Supervisor.stop(pid)
  end

  defp stop_supervisor_if_running do
    case Process.whereis(Hivebeam.Supervisor) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        _ = Supervisor.stop(pid)
        :ok
    end
  rescue
    _ -> :ok
  end
end
