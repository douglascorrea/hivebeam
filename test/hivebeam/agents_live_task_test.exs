defmodule Hivebeam.AgentsLiveTaskTest do
  use ExUnit.Case, async: false

  alias Hivebeam.Inventory

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "hivebeam_agents_live_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)

    old_root = System.get_env("HIVEBEAM_CONFIG_ROOT")
    old_inv = System.get_env("HIVEBEAM_INVENTORY_PATH")
    old_mode = System.get_env("HIVEBEAM_DISCOVERY_MODE")

    System.put_env("HIVEBEAM_CONFIG_ROOT", root)
    System.delete_env("HIVEBEAM_INVENTORY_PATH")
    System.put_env("HIVEBEAM_DISCOVERY_MODE", "inventory")

    on_exit(fn ->
      if is_binary(old_root),
        do: System.put_env("HIVEBEAM_CONFIG_ROOT", old_root),
        else: System.delete_env("HIVEBEAM_CONFIG_ROOT")

      if is_binary(old_inv),
        do: System.put_env("HIVEBEAM_INVENTORY_PATH", old_inv),
        else: System.delete_env("HIVEBEAM_INVENTORY_PATH")

      if is_binary(old_mode),
        do: System.put_env("HIVEBEAM_DISCOVERY_MODE", old_mode),
        else: System.delete_env("HIVEBEAM_DISCOVERY_MODE")

      File.rm_rf(root)
    end)

    :ok
  end

  test "chat does not silently fall back to local when only hosts exist" do
    inventory =
      Inventory.upsert_host(%{
        "alias" => "hetzner",
        "ssh" => "user@hetzner",
        "remote_path" => "~/.local/hivebeam/current",
        "tags" => ["prod"]
      })

    assert :ok = Inventory.save(inventory)

    Mix.Task.reenable("agents.live")

    assert_raise Mix.Error, ~r/Inventory has hosts but no managed nodes yet/, fn ->
      Mix.Tasks.Agents.Live.run(["--chat"])
    end
  end
end
