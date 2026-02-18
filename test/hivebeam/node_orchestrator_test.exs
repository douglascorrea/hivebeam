defmodule Hivebeam.NodeOrchestratorTest do
  use ExUnit.Case, async: true

  alias Hivebeam.NodeOrchestrator

  test "build_runtime derives deterministic local defaults from slot" do
    assert {:ok, runtime} =
             NodeOrchestrator.build_runtime(name: "box2", provider: "claude", cwd: File.cwd!())

    assert runtime.project_name == "hivebeam_box2"
    assert runtime.docker == false
    assert runtime.slot == 2
    assert runtime.bind_ip == "127.0.0.12"
    assert runtime.host_ip == "127.0.0.12"
    assert runtime.node_name == "claude@127.0.0.12"
    assert runtime.dist_port == 9101
    assert runtime.tcp_port == 5052
    assert runtime.debug_port == 1456
    assert runtime.epmd_port == 4369
    assert String.ends_with?(runtime.pid_file, ".hivebeam/nodes/box2.pid")
    assert String.ends_with?(runtime.log_file, ".hivebeam/nodes/box2.log")
  end

  test "build_runtime enables docker mode when --docker is set" do
    assert {:ok, runtime} =
             NodeOrchestrator.build_runtime(name: "box1", docker: true, cwd: File.cwd!())

    assert runtime.docker == true
    assert runtime.bind_ip == "127.0.0.11"
  end

  test "build_runtime derives remote defaults from ssh host" do
    assert {:ok, runtime} =
             NodeOrchestrator.build_runtime(
               name: "edge1",
               remote: "user@10.0.0.20",
               cwd: "/workspace"
             )

    assert runtime.remote == "user@10.0.0.20"
    assert runtime.remote_path == "~/.local/hivebeam/current"
    assert runtime.bind_ip == "0.0.0.0"
    assert runtime.host_ip == "10.0.0.20"
    assert runtime.node_name == "codex@10.0.0.20"
  end

  test "build_runtime reuses persisted runtime metadata when explicit flags are missing" do
    tmp_dir = temp_dir("node_orchestrator_meta")
    runtime_dir = Path.join(tmp_dir, ".hivebeam/nodes")
    File.mkdir_p!(runtime_dir)

    meta = %{
      "provider" => "claude",
      "slot" => 2,
      "docker" => false,
      "bind_ip" => "0.0.0.0",
      "host_ip" => "157.180.81.117",
      "cookie" => "hivebeam_cookie",
      "dist_port" => 9101,
      "tcp_port" => 5052,
      "debug_port" => 1456,
      "epmd_port" => 4369,
      "compose_file" => "docker-compose.yml"
    }

    File.write!(Path.join(runtime_dir, "edge2.json"), Jason.encode!(meta))

    assert {:ok, runtime} =
             NodeOrchestrator.build_runtime(
               name: "edge2",
               hydrate_metadata: true,
               remote_path: tmp_dir,
               cwd: tmp_dir
             )

    assert runtime.provider == "claude"
    assert runtime.host_ip == "157.180.81.117"
    assert runtime.node_name == "claude@157.180.81.117"
    assert runtime.dist_port == 9101
    assert runtime.tcp_port == 5052
    assert runtime.debug_port == 1456
  end

  test "compose_env includes deterministic port and node settings" do
    {:ok, runtime} =
      NodeOrchestrator.build_runtime(name: "box1", provider: "codex", slot: 3, cwd: File.cwd!())

    env = NodeOrchestrator.compose_env(runtime)

    assert env["HIVEBEAM_ACP_PROVIDER"] == "codex"
    assert env["HIVEBEAM_NODE_NAME"] == "codex@127.0.0.13"
    assert env["HIVEBEAM_BIND_IP"] == "127.0.0.13"
    assert env["HIVEBEAM_ERL_DIST_PORT"] == "9102"
    assert env["HIVEBEAM_TCP_HOST_PORT"] == "5053"
    assert env["HIVEBEAM_DEBUG_HOST_PORT"] == "1457"
    assert env["HIVEBEAM_EPMD_HOST_PORT"] == "4369"
  end

  test "compose_args build expected commands" do
    {:ok, runtime} = NodeOrchestrator.build_runtime(name: "box1", cwd: File.cwd!())

    assert NodeOrchestrator.compose_args(runtime, :up) == [
             "compose",
             "-f",
             "docker-compose.yml",
             "-p",
             "hivebeam_box1",
             "up",
             "-d",
             "--build"
           ]

    assert NodeOrchestrator.compose_args(runtime, :down) == [
             "compose",
             "-f",
             "docker-compose.yml",
             "-p",
             "hivebeam_box1",
             "down",
             "--remove-orphans"
           ]
  end

  defp temp_dir(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
