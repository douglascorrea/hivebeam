defmodule ElxDockerNode.CodexConfigTest do
  use ExUnit.Case, async: false

  alias ElxDockerNode.CodexConfig

  test "uses defaults when env vars are missing" do
    with_env(
      [
        {"ELX_CODEX_ACP_CMD", nil},
        {"ELX_CLUSTER_NODES", nil},
        {"ELX_CLUSTER_RETRY_MS", nil},
        {"ELX_CODEX_PROMPT_TIMEOUT_MS", nil},
        {"ELX_CODEX_CONNECT_TIMEOUT_MS", nil},
        {"ELX_CODEX_BRIDGE_NAME", nil}
      ],
      fn ->
        assert {:ok, {"codex-acp", []}} = CodexConfig.acp_command()
        assert CodexConfig.cluster_nodes() == []
        assert CodexConfig.cluster_retry_ms() == 5_000
        assert CodexConfig.prompt_timeout_ms() == 120_000
        assert CodexConfig.connect_timeout_ms() == 30_000
        assert CodexConfig.bridge_name() == ElxDockerNode.CodexBridge
      end
    )
  end

  test "parses command and cluster env vars" do
    with_env(
      [
        {"ELX_CODEX_ACP_CMD", "docker compose exec -T codex-node codex-acp"},
        {"ELX_CLUSTER_NODES", "codex@node-a, codex@node-b"}
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
        {"ELX_CLUSTER_RETRY_MS", "abc"},
        {"ELX_CODEX_PROMPT_TIMEOUT_MS", "-1"},
        {"ELX_CODEX_CONNECT_TIMEOUT_MS", "0"}
      ],
      fn ->
        assert CodexConfig.cluster_retry_ms() == 5_000
        assert CodexConfig.prompt_timeout_ms() == 120_000
        assert CodexConfig.connect_timeout_ms() == 30_000
      end
    )
  end

  test "parses custom bridge names" do
    with_env([{"ELX_CODEX_BRIDGE_NAME", "ElxDockerNode.CustomBridge"}], fn ->
      assert CodexConfig.bridge_name() == ElxDockerNode.CustomBridge
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
end
