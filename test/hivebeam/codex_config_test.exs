defmodule Hivebeam.CodexConfigTest do
  use ExUnit.Case, async: false

  alias Hivebeam.CodexConfig

  test "uses defaults when env vars are missing" do
    with_env(
      [
        {"HIVEBEAM_CODEX_ACP_CMD", nil},
        {"HIVEBEAM_CLUSTER_NODES", nil},
        {"HIVEBEAM_CLUSTER_RETRY_MS", nil},
        {"HIVEBEAM_CODEX_PROMPT_TIMEOUT_MS", nil},
        {"HIVEBEAM_CODEX_CONNECT_TIMEOUT_MS", nil},
        {"HIVEBEAM_CODEX_BRIDGE_NAME", nil}
      ],
      fn ->
        assert {:ok, {command, []}} = CodexConfig.acp_command()
        assert is_binary(command) and command != ""
        assert CodexConfig.cluster_nodes() == []
        assert CodexConfig.cluster_retry_ms() == 5_000
        assert CodexConfig.prompt_timeout_ms() == 120_000
        assert CodexConfig.connect_timeout_ms() == 30_000
        assert CodexConfig.bridge_name() == Hivebeam.CodexBridge
      end
    )
  end

  test "parses command and cluster env vars" do
    with_env(
      [
        {"HIVEBEAM_CODEX_ACP_CMD", "docker compose exec -T codex-node codex-acp"},
        {"HIVEBEAM_CLUSTER_NODES", "codex@node-a, codex@node-b"}
      ],
      fn ->
        assert {:ok, {"docker", ["compose", "exec", "-T", "codex-node", "codex-acp"]}} =
                 CodexConfig.acp_command()

        assert CodexConfig.cluster_nodes() == [:"codex@node-a", :"codex@node-b"]
      end
    )
  end

  test "falls back to defaults when integer envs are invalid" do
    with_env(
      [
        {"HIVEBEAM_CLUSTER_RETRY_MS", "abc"},
        {"HIVEBEAM_CODEX_PROMPT_TIMEOUT_MS", "-1"},
        {"HIVEBEAM_CODEX_CONNECT_TIMEOUT_MS", "0"}
      ],
      fn ->
        assert CodexConfig.cluster_retry_ms() == 5_000
        assert CodexConfig.prompt_timeout_ms() == 120_000
        assert CodexConfig.connect_timeout_ms() == 30_000
      end
    )
  end

  test "parses custom bridge names" do
    with_env([{"HIVEBEAM_CODEX_BRIDGE_NAME", "Hivebeam.CustomBridge"}], fn ->
      assert CodexConfig.bridge_name() == Hivebeam.CustomBridge
    end)
  end

  test "prefers sibling codex-acp build when env command is not set" do
    with_env([{"HIVEBEAM_CODEX_ACP_CMD", nil}], fn ->
      with_temp_dir("acp_cfg", fn tmp_dir ->
        app_dir = Path.join(tmp_dir, "hivebeam")
        sibling_dir = Path.join(tmp_dir, "codex-acp")
        release_dir = Path.join([sibling_dir, "target", "release"])
        binary_path = Path.join(release_dir, "codex-acp")

        File.mkdir_p!(app_dir)
        File.mkdir_p!(release_dir)
        File.write!(binary_path, "#!/bin/sh\nexit 0\n")
        File.chmod!(binary_path, 0o755)

        with_cwd(app_dir, fn ->
          expected_suffix = Path.join(["codex-acp", "target", "release", "codex-acp"])
          default_command = CodexConfig.default_acp_command()
          assert String.ends_with?(default_command, expected_suffix)
          assert File.read!(default_command) == "#!/bin/sh\nexit 0\n"
          assert {:ok, {resolved_path, []}} = CodexConfig.acp_command()
          assert String.ends_with?(resolved_path, expected_suffix)
          assert File.read!(resolved_path) == "#!/bin/sh\nexit 0\n"
        end)
      end)
    end)
  end

  defp with_env(pairs, fun) do
    previous = Enum.map(pairs, fn {key, _} -> {key, System.get_env(key)} end)

    Enum.each(pairs, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp with_temp_dir(prefix, fun) when is_function(fun, 1) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)

    try do
      fun.(path)
    after
      File.rm_rf(path)
    end
  end

  defp with_cwd(path, fun) when is_binary(path) and is_function(fun, 0) do
    previous = File.cwd!()
    File.cd!(path)

    try do
      fun.()
    after
      File.cd!(previous)
    end
  end
end
