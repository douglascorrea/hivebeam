defmodule Hivebeam.InventoryTest do
  use ExUnit.Case, async: false

  alias Hivebeam.Inventory

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "hivebeam_inventory_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)

    old_root = System.get_env("HIVEBEAM_CONFIG_ROOT")
    old_inv = System.get_env("HIVEBEAM_INVENTORY_PATH")

    System.put_env("HIVEBEAM_CONFIG_ROOT", root)
    System.delete_env("HIVEBEAM_INVENTORY_PATH")

    on_exit(fn ->
      if is_binary(old_root),
        do: System.put_env("HIVEBEAM_CONFIG_ROOT", old_root),
        else: System.delete_env("HIVEBEAM_CONFIG_ROOT")

      if is_binary(old_inv),
        do: System.put_env("HIVEBEAM_INVENTORY_PATH", old_inv),
        else: System.delete_env("HIVEBEAM_INVENTORY_PATH")

      File.rm_rf(root)
    end)

    :ok
  end

  test "upsert host and node with selector filtering" do
    inventory =
      Inventory.upsert_host(%{
        "alias" => "prod-a",
        "ssh" => "user@prod-a",
        "remote_path" => "~/.local/hivebeam/current",
        "tags" => ["prod", "edge"]
      })

    inventory =
      Inventory.upsert_node(
        %{
          "name" => "edge1",
          "host_alias" => "prod-a",
          "provider" => "codex",
          "mode" => "native",
          "managed" => true,
          "node_name" => "codex@10.0.0.10",
          "state" => "up"
        },
        inventory
      )

    assert :ok = Inventory.save(inventory)

    assert [%{"name" => "edge1"}] = Inventory.select_nodes(["all"])
    assert [%{"name" => "edge1"}] = Inventory.select_nodes(["host:prod-a"])
    assert [%{"name" => "edge1"}] = Inventory.select_nodes(["tag:prod"])
    assert [%{"name" => "edge1"}] = Inventory.select_nodes(["provider:codex"])
    assert [] = Inventory.select_nodes(["provider:claude"])
  end

  test "record_runtime creates host and node entries" do
    runtime = %{
      name: "edge2",
      provider: "claude",
      docker: false,
      remote: "user@remote-host",
      remote_path: "~/.local/hivebeam/current",
      node_name: "claude@remote-host"
    }

    inventory = Inventory.record_runtime(runtime)
    assert :ok = Inventory.save(inventory)

    loaded = Inventory.load()

    assert Enum.any?(loaded["hosts"], fn host -> host["ssh"] == "user@remote-host" end)

    assert Enum.any?(loaded["nodes"], fn node ->
             node["name"] == "edge2" and node["provider"] == "claude"
           end)
  end
end
