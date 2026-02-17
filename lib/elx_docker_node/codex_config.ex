defmodule ElxDockerNode.CodexConfig do
  @moduledoc false

  @default_acp_command "codex-acp"
  @default_cluster_retry_ms 5_000
  @default_prompt_timeout_ms 120_000
  @default_connect_timeout_ms 30_000
  @default_bridge_name ElxDockerNode.CodexBridge

  @spec acp_command() :: {:ok, {String.t(), [String.t()]}} | {:error, term()}
  def acp_command do
    @default_acp_command
    |> env("ELX_CODEX_ACP_CMD")
    |> parse_acp_command()
  end

  @spec parse_acp_command(String.t() | nil) ::
          {:ok, {String.t(), [String.t()]}} | {:error, term()}
  def parse_acp_command(nil), do: {:error, :empty_acp_command}

  def parse_acp_command(command) when is_binary(command) do
    command
    |> String.trim()
    |> OptionParser.split()
    |> case do
      [] -> {:error, :empty_acp_command}
      [path | args] -> {:ok, {path, args}}
    end
  end

  @spec cluster_nodes() :: [node()]
  def cluster_nodes do
    ""
    |> env("ELX_CLUSTER_NODES")
    |> parse_cluster_nodes()
  end

  @spec parse_cluster_nodes(String.t() | nil) :: [node()]
  def parse_cluster_nodes(nil), do: []

  def parse_cluster_nodes(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_atom/1)
  end

  @spec cluster_retry_ms() :: pos_integer()
  def cluster_retry_ms, do: int_env("ELX_CLUSTER_RETRY_MS", @default_cluster_retry_ms)

  @spec prompt_timeout_ms() :: pos_integer()
  def prompt_timeout_ms, do: int_env("ELX_CODEX_PROMPT_TIMEOUT_MS", @default_prompt_timeout_ms)

  @spec connect_timeout_ms() :: pos_integer()
  def connect_timeout_ms, do: int_env("ELX_CODEX_CONNECT_TIMEOUT_MS", @default_connect_timeout_ms)

  @spec bridge_name() :: atom()
  def bridge_name do
    nil
    |> env("ELX_CODEX_BRIDGE_NAME")
    |> parse_bridge_name()
  end

  @spec parse_bridge_name(String.t() | atom() | nil) :: atom()
  def parse_bridge_name(nil), do: @default_bridge_name
  def parse_bridge_name(name) when is_atom(name), do: name

  def parse_bridge_name(name) when is_binary(name) do
    value = String.trim(name)

    cond do
      value == "" ->
        @default_bridge_name

      String.starts_with?(value, ":") ->
        value
        |> String.trim_leading(":")
        |> String.to_atom()

      String.starts_with?(value, "Elixir.") ->
        String.to_atom(value)

      String.contains?(value, ".") ->
        Module.concat([value])

      true ->
        String.to_atom(value)
    end
  end

  defp int_env(env_name, default) do
    case System.get_env(env_name) do
      nil ->
        default

      value ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end

  defp env(default, env_name), do: System.get_env(env_name, default)
end
