defmodule Hivebeam.DiscoveryManagerTest do
  use ExUnit.Case, async: false

  alias Hivebeam.DiscoveryManager
  alias Hivebeam.Inventory

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "hivebeam_discovery_#{System.unique_integer([:positive, :monotonic])}"
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

  test "discover returns inventory-managed nodes first" do
    inventory =
      Inventory.upsert_host(%{"alias" => "prod-a", "ssh" => "user@prod-a", "tags" => ["prod"]})

    inventory =
      Inventory.upsert_node(
        %{
          "name" => "edge1",
          "host_alias" => "prod-a",
          "provider" => "codex",
          "node_name" => "codex@10.0.0.10",
          "state" => "up",
          "managed" => true
        },
        inventory
      )

    assert :ok = Inventory.save(inventory)

    result = DiscoveryManager.discover(selectors: ["all"])

    assert result.mode == :inventory
    assert result.nodes == [:"codex@10.0.0.10"]
    assert result.node_aliases["codex@10.0.0.10"] == "edge1"
  end
end
