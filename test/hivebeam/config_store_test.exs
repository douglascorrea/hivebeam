defmodule Hivebeam.ConfigStoreTest do
  use ExUnit.Case, async: false

  alias Hivebeam.ConfigStore

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "hivebeam_config_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)

    old_root = System.get_env("HIVEBEAM_CONFIG_ROOT")
    old_path = System.get_env("HIVEBEAM_CONFIG_PATH")

    System.put_env("HIVEBEAM_CONFIG_ROOT", root)
    System.delete_env("HIVEBEAM_CONFIG_PATH")

    on_exit(fn ->
      if is_binary(old_root),
        do: System.put_env("HIVEBEAM_CONFIG_ROOT", old_root),
        else: System.delete_env("HIVEBEAM_CONFIG_ROOT")

      if is_binary(old_path),
        do: System.put_env("HIVEBEAM_CONFIG_PATH", old_path),
        else: System.delete_env("HIVEBEAM_CONFIG_PATH")

      File.rm_rf(root)
    end)

    :ok
  end

  test "load returns sane defaults" do
    config = ConfigStore.load()

    assert config["install_root"] == "~/.local/hivebeam"
    assert config["default_remote_path"] == "~/.local/hivebeam/current"
    assert config["default_cookie"] == "hivebeam_cookie"
    assert config["discovery_mode"] == "hybrid"
    assert config["keymap"] == "standard"
  end

  test "save persists values" do
    assert :ok =
             ConfigStore.save(%{
               "discovery_mode" => "inventory",
               "default_cookie" => "abc",
               "default_providers" => ["codex"],
               "ui_auto_layout" => false
             })

    config = ConfigStore.load()

    assert config["discovery_mode"] == "inventory"
    assert config["default_cookie"] == "abc"
    assert config["default_providers"] == ["codex"]
    assert config["ui_auto_layout"] == false
  end
end
