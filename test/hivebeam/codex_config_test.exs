defmodule Hivebeam.CodexConfigTest do
  use ExUnit.Case, async: false

  alias Hivebeam.CodexConfig

  test "uses defaults when env vars are missing" do
    with_env(
      [
        {"HIVEBEAM_ACP_PROVIDER", nil},
        {"HIVEBEAM_CODEX_ACP_CMD", nil},
        {"HIVEBEAM_CLAUDE_AGENT_ACP_CMD", nil},
        {"HIVEBEAM_ACP_RECONNECT_MS", nil},
        {"HIVEBEAM_CODEX_PROMPT_TIMEOUT_MS", nil},
        {"HIVEBEAM_CODEX_CONNECT_TIMEOUT_MS", nil},
        {"HIVEBEAM_CODEX_BRIDGE_NAME", nil}
      ],
      fn ->
        assert CodexConfig.acp_provider() == "codex"
        assert {:ok, {command, []}} = CodexConfig.acp_command()
        assert is_binary(command) and command != ""
        assert CodexConfig.reconnect_ms() == 5_000
        assert CodexConfig.prompt_timeout_ms() == 120_000
        assert CodexConfig.connect_timeout_ms() == 30_000
        assert CodexConfig.bridge_name() == Hivebeam.CodexBridge
      end
    )
  end

  test "parses codex command env var" do
    with_env(
      [
        {"HIVEBEAM_ACP_PROVIDER", "codex"},
        {"HIVEBEAM_CODEX_ACP_CMD", "docker compose exec -T codex-node codex-acp"},
        {"HIVEBEAM_CLAUDE_AGENT_ACP_CMD", nil}
      ],
      fn ->
        assert {:ok, {"docker", ["compose", "exec", "-T", "codex-node", "codex-acp"]}} =
                 CodexConfig.acp_command()
      end
    )
  end

  test "uses claude provider command when configured" do
    with_env(
      [
        {"HIVEBEAM_ACP_PROVIDER", "claude"},
        {"HIVEBEAM_CLAUDE_AGENT_ACP_CMD", "docker compose exec -T claude-node claude-agent-acp"},
        {"HIVEBEAM_CODEX_ACP_CMD", "docker compose exec -T codex-node codex-acp"}
      ],
      fn ->
        assert CodexConfig.acp_provider() == "claude"

        assert {:ok, {"docker", ["compose", "exec", "-T", "claude-node", "claude-agent-acp"]}} =
                 CodexConfig.acp_command()
      end
    )
  end

  test "returns clear error for unsupported provider" do
    with_env(
      [
        {"HIVEBEAM_ACP_PROVIDER", "unknown"},
        {"HIVEBEAM_CODEX_ACP_CMD", nil},
        {"HIVEBEAM_CLAUDE_AGENT_ACP_CMD", nil}
      ],
      fn ->
        assert CodexConfig.acp_provider() == "unknown"
        assert {:error, {:unsupported_acp_provider, "unknown"}} = CodexConfig.acp_command()
      end
    )
  end

  test "acp_command/1 can resolve explicit provider independent of env default" do
    with_env(
      [
        {"HIVEBEAM_ACP_PROVIDER", "codex"},
        {"HIVEBEAM_CODEX_ACP_CMD", "codex-acp"},
        {"HIVEBEAM_CLAUDE_AGENT_ACP_CMD", "claude-agent-acp"}
      ],
      fn ->
        assert {:ok, {"claude-agent-acp", []}} = CodexConfig.acp_command("claude")
        assert {:ok, {"codex-acp", []}} = CodexConfig.acp_command("codex")
      end
    )
  end

  test "default_claude_acp_command falls back to npx when claude-agent-acp is unavailable" do
    with_temp_dir("claude_acp_path", fn tmp_dir ->
      npx_path = Path.join(tmp_dir, "npx")
      File.write!(npx_path, "#!/bin/sh\nexit 0\n")
      File.chmod!(npx_path, 0o755)

      with_env(
        [
          {"PATH", tmp_dir},
          {"HIVEBEAM_CLAUDE_AGENT_ACP_CMD", nil}
        ],
        fn ->
          assert CodexConfig.default_claude_acp_command() ==
                   "npx -y @zed-industries/claude-agent-acp"

          assert {:ok, {"npx", ["-y", "@zed-industries/claude-agent-acp"]}} =
                   CodexConfig.acp_command("claude")
        end
      )
    end)
  end

  test "command_available?/1 validates executable path and PATH lookup" do
    assert CodexConfig.command_available?({"this-command-should-not-exist-xyz", []}) == false
    assert CodexConfig.command_available?({"/tmp/this-file-does-not-exist", []}) == false
  end

  test "falls back to defaults when integer envs are invalid" do
    with_env(
      [
        {"HIVEBEAM_ACP_RECONNECT_MS", "abc"},
        {"HIVEBEAM_CODEX_PROMPT_TIMEOUT_MS", "-1"},
        {"HIVEBEAM_CODEX_CONNECT_TIMEOUT_MS", "0"}
      ],
      fn ->
        assert CodexConfig.reconnect_ms() == 5_000
        assert CodexConfig.prompt_timeout_ms() == 120_000
        assert CodexConfig.connect_timeout_ms() == 30_000
      end
    )
  end

  test "parses custom bridge names" do
    with_env(
      [
        {"HIVEBEAM_ACP_PROVIDER", "codex"},
        {"HIVEBEAM_CODEX_BRIDGE_NAME", "Hivebeam.CustomBridge"}
      ],
      fn ->
        assert CodexConfig.bridge_name() == Hivebeam.CustomBridge
      end
    )
  end

  test "prefers installed codex-acp over sibling build when env command is not set" do
    with_temp_dir("acp_cfg", fn tmp_dir ->
      app_dir = Path.join(tmp_dir, "hivebeam")
      sibling_dir = Path.join(tmp_dir, "codex-acp")
      release_dir = Path.join([sibling_dir, "target", "release"])
      sibling_binary_path = Path.join(release_dir, "codex-acp")
      bin_dir = Path.join(tmp_dir, "bin")
      installed_binary_path = Path.join(bin_dir, "codex-acp")

      File.mkdir_p!(app_dir)
      File.mkdir_p!(release_dir)
      File.mkdir_p!(bin_dir)
      File.write!(sibling_binary_path, "#!/bin/sh\necho sibling\n")
      File.write!(installed_binary_path, "#!/bin/sh\necho installed\n")
      File.chmod!(sibling_binary_path, 0o755)
      File.chmod!(installed_binary_path, 0o755)

      with_env(
        [
          {"HIVEBEAM_ACP_PROVIDER", "codex"},
          {"HIVEBEAM_CODEX_ACP_CMD", nil},
          {"HIVEBEAM_CLAUDE_AGENT_ACP_CMD", nil},
          {"PATH", bin_dir}
        ],
        fn ->
          with_cwd(app_dir, fn ->
            default_command = CodexConfig.default_acp_command()
            assert default_command == installed_binary_path
            assert File.read!(default_command) == "#!/bin/sh\necho installed\n"
            assert {:ok, {resolved_path, []}} = CodexConfig.acp_command()
            assert resolved_path == installed_binary_path
            assert File.read!(resolved_path) == "#!/bin/sh\necho installed\n"
          end)
        end
      )
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
