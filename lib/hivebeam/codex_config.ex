defmodule Hivebeam.CodexConfig do
  @moduledoc false

  @default_acp_provider "codex"
  @default_acp_command "codex-acp"
  @default_claude_acp_command "claude-agent-acp"
  @default_claude_acp_npx_command "npx -y @zed-industries/claude-agent-acp"
  @default_reconnect_ms 5_000
  @default_prompt_timeout_ms 120_000
  @default_connect_timeout_ms 30_000
  @default_bridge_name Hivebeam.CodexBridge
  @default_claude_bridge_name Hivebeam.ClaudeBridge

  @spec acp_provider() :: String.t()
  def acp_provider do
    @default_acp_provider
    |> env("HIVEBEAM_ACP_PROVIDER")
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> @default_acp_provider
      provider -> provider
    end
  end

  @spec acp_command() :: {:ok, {String.t(), [String.t()]}} | {:error, term()}
  def acp_command, do: acp_command(acp_provider())

  @spec acp_command(String.t() | atom()) :: {:ok, {String.t(), [String.t()]}} | {:error, term()}
  def acp_command(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> acp_command()
  end

  def acp_command(provider) when is_binary(provider) do
    case provider |> String.trim() |> String.downcase() do
      "codex" ->
        command_from_env("HIVEBEAM_CODEX_ACP_CMD", default_acp_command())

      "claude" ->
        command_from_env("HIVEBEAM_CLAUDE_AGENT_ACP_CMD", default_claude_acp_command())

      normalized_provider ->
        {:error, {:unsupported_acp_provider, normalized_provider}}
    end
  end

  @spec default_acp_command() :: String.t()
  def default_acp_command do
    discover_local_acp_path() || @default_acp_command
  end

  @spec default_claude_acp_command() :: String.t()
  def default_claude_acp_command do
    cond do
      not is_nil(System.find_executable(@default_claude_acp_command)) ->
        @default_claude_acp_command

      not is_nil(System.find_executable("npx")) ->
        @default_claude_acp_npx_command

      true ->
        @default_claude_acp_command
    end
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

  @spec command_available?({String.t(), [String.t()]} | {:ok, {String.t(), [String.t()]}}) ::
          boolean()
  def command_available?({:ok, command}), do: command_available?(command)

  def command_available?({path, _args}) when is_binary(path) do
    cond do
      path == "" ->
        false

      Path.type(path) == :absolute ->
        File.exists?(path)

      String.starts_with?(path, "./") or String.starts_with?(path, "../") ->
        path
        |> Path.expand(File.cwd!())
        |> File.exists?()

      true ->
        not is_nil(System.find_executable(path))
    end
  end

  def command_available?(_), do: false

  @spec reconnect_ms() :: pos_integer()
  def reconnect_ms, do: int_env("HIVEBEAM_ACP_RECONNECT_MS", @default_reconnect_ms)

  @spec prompt_timeout_ms() :: pos_integer()
  def prompt_timeout_ms,
    do: int_env("HIVEBEAM_CODEX_PROMPT_TIMEOUT_MS", @default_prompt_timeout_ms)

  @spec connect_timeout_ms() :: pos_integer()
  def connect_timeout_ms,
    do: int_env("HIVEBEAM_CODEX_CONNECT_TIMEOUT_MS", @default_connect_timeout_ms)

  @spec bridge_name() :: atom()
  def bridge_name do
    nil
    |> env("HIVEBEAM_CODEX_BRIDGE_NAME")
    |> parse_bridge_name(@default_bridge_name)
  end

  @spec claude_bridge_name() :: atom()
  def claude_bridge_name do
    nil
    |> env("HIVEBEAM_CLAUDE_BRIDGE_NAME")
    |> parse_bridge_name(@default_claude_bridge_name)
  end

  @spec bridge_name(String.t() | atom()) :: atom()
  def bridge_name(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> bridge_name()
  end

  def bridge_name(provider) when is_binary(provider) do
    case provider |> String.trim() |> String.downcase() do
      "claude" -> claude_bridge_name()
      _ -> bridge_name()
    end
  end

  @spec parse_bridge_name(String.t() | atom() | nil) :: atom()
  def parse_bridge_name(name), do: parse_bridge_name(name, @default_bridge_name)

  defp parse_bridge_name(nil, default), do: default
  defp parse_bridge_name(name, _default) when is_atom(name), do: name

  defp parse_bridge_name(name, default) when is_binary(name) do
    value = String.trim(name)

    cond do
      value == "" ->
        default

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

  defp discover_local_acp_path do
    File.cwd!()
    |> local_acp_candidates()
    |> Enum.find(&File.exists?/1)
  end

  defp local_acp_candidates(cwd) when is_binary(cwd) do
    sibling_release = Path.expand("../codex-acp/target/release/codex-acp", cwd)
    sibling_debug = Path.expand("../codex-acp/target/debug/codex-acp", cwd)

    home_candidate =
      case System.user_home() do
        nil -> nil
        home -> Path.join([home, ".cargo", "bin", "codex-acp"])
      end

    [sibling_release, sibling_debug, home_candidate, "/usr/local/cargo/bin/codex-acp"]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
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

  defp command_from_env(env_name, default_command) do
    case System.get_env(env_name) do
      nil ->
        parse_acp_command(default_command)

      value when is_binary(value) ->
        if String.trim(value) == "" do
          parse_acp_command(default_command)
        else
          parse_acp_command(value)
        end
    end
  end

  defp env(default, env_name), do: System.get_env(env_name, default)
end
