defmodule Hivebeam.NodeOrchestratorInventoryHydrationTest do
  use ExUnit.Case, async: false

  alias Hivebeam.Inventory
  alias Hivebeam.NodeOrchestrator

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "hivebeam_node_orchestrator_inventory_#{System.unique_integer([:positive, :monotonic])}"
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

  test "build_runtime hydrates remote target from inventory node by name" do
    inventory =
      Inventory.upsert_host(%{
        "alias" => "hetzner",
        "ssh" => "user@hetzner-douglas",
        "remote_path" => "~/.local/hivebeam/current",
        "tags" => ["hetzner"]
      })

    inventory =
      Inventory.upsert_node(
        %{
          "name" => "edge1",
          "host_alias" => "hetzner",
          "provider" => "codex",
          "mode" => "native",
          "managed" => true,
          "node_name" => "codex@hetzner-douglas",
          "state" => "down"
        },
        inventory
      )

    assert :ok = Inventory.save(inventory)

    assert {:ok, runtime} =
             NodeOrchestrator.build_runtime(
               name: "edge1",
               hydrate_inventory: true,
               cwd: "/workspace"
             )

    assert runtime.remote == "user@hetzner-douglas"
    assert runtime.remote_path == "~/.local/hivebeam/current"
    assert runtime.provider == "codex"
    assert runtime.node_name == "codex@hetzner-douglas"
  end

  test "build_runtime maps host ssh=local to local runtime with host remote_path" do
    inventory =
      Inventory.upsert_host(%{
        "alias" => "local",
        "ssh" => "local",
        "remote_path" => "/tmp/hivebeam-local-runtime",
        "tags" => ["local"]
      })

    inventory =
      Inventory.upsert_node(
        %{
          "name" => "edge-local",
          "host_alias" => "local",
          "provider" => "codex",
          "mode" => "native",
          "managed" => true,
          "node_name" => "codex@127.0.0.11",
          "state" => "down"
        },
        inventory
      )

    assert :ok = Inventory.save(inventory)

    assert {:ok, runtime} =
             NodeOrchestrator.build_runtime(
               name: "edge-local",
               hydrate_inventory: true,
               cwd: "/workspace"
             )

    assert runtime.remote == nil
    assert runtime.remote_path == "/tmp/hivebeam-local-runtime"
    assert runtime.provider == "codex"
  end

  test "up without --remote requires existing inventory node" do
    assert {:error, {:target_resolution_failed, reason}} =
             NodeOrchestrator.up(name: "missing-edge", cwd: "/workspace")

    assert reason =~ "No inventory node named missing-edge"
  end
end
