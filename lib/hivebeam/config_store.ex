defmodule Hivebeam.ConfigStore do
  @moduledoc false

  alias Hivebeam.TomlLite

  @default_install_root "~/.local/hivebeam"
  @default_remote_path "~/.local/hivebeam/current"
  @default_cookie "hivebeam_cookie"
  @default_discovery_mode "hybrid"
  @default_keymap "standard"

  @spec defaults() :: map()
  def defaults do
    %{
      "install_root" => @default_install_root,
      "default_remote_path" => @default_remote_path,
      "default_cookie" => @default_cookie,
      "default_providers" => ["codex", "claude"],
      "discovery_mode" => @default_discovery_mode,
      "ui_auto_layout" => true,
      "keymap" => @default_keymap
    }
  end

  @spec path() :: String.t()
  def path do
    System.get_env("HIVEBEAM_CONFIG_PATH") ||
      Path.join([config_root(), "config.toml"])
  end

  @spec load() :: map()
  def load do
    default = defaults()

    parsed =
      case File.read(path()) do
        {:ok, raw} ->
          case TomlLite.decode(raw) do
            {:ok, value} when is_map(value) -> value
            _ -> %{}
          end

        _ ->
          %{}
      end

    default
    |> Map.merge(parsed)
    |> normalize()
  end

  @spec save(map()) :: :ok | {:error, term()}
  def save(config) when is_map(config) do
    normalized = normalize(Map.merge(defaults(), config))

    with :ok <- File.mkdir_p(config_root()) do
      File.write(path(), TomlLite.encode(normalized))
    end
  end

  @spec install_root() :: String.t()
  def install_root, do: Map.fetch!(load(), "install_root")

  @spec default_remote_path() :: String.t()
  def default_remote_path, do: Map.fetch!(load(), "default_remote_path")

  @spec default_cookie() :: String.t()
  def default_cookie, do: Map.fetch!(load(), "default_cookie")

  @spec default_providers() :: [String.t()]
  def default_providers, do: Map.fetch!(load(), "default_providers")

  @spec discovery_mode() :: String.t()
  def discovery_mode, do: Map.fetch!(load(), "discovery_mode")

  @spec ui_auto_layout?() :: boolean()
  def ui_auto_layout?, do: Map.fetch!(load(), "ui_auto_layout") == true

  @spec keymap() :: String.t()
  def keymap, do: Map.fetch!(load(), "keymap")

  defp normalize(config) do
    %{
      "install_root" => normalize_string(Map.get(config, "install_root"), @default_install_root),
      "default_remote_path" =>
        normalize_string(Map.get(config, "default_remote_path"), @default_remote_path),
      "default_cookie" => normalize_string(Map.get(config, "default_cookie"), @default_cookie),
      "default_providers" => normalize_providers(Map.get(config, "default_providers")),
      "discovery_mode" => normalize_discovery_mode(Map.get(config, "discovery_mode")),
      "ui_auto_layout" => normalize_boolean(Map.get(config, "ui_auto_layout"), true),
      "keymap" => normalize_string(Map.get(config, "keymap"), @default_keymap)
    }
  end

  defp normalize_providers(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> case do
      [] -> ["codex", "claude"]
      providers -> providers
    end
  end

  defp normalize_providers(value) when is_binary(value) do
    value
    |> String.split(",")
    |> normalize_providers()
  end

  defp normalize_providers(_), do: ["codex", "claude"]

  defp normalize_discovery_mode(value) do
    mode = normalize_string(value, @default_discovery_mode)

    if mode in ["inventory", "libcluster", "hybrid"] do
      mode
    else
      @default_discovery_mode
    end
  end

  defp normalize_string(value, default) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: default, else: trimmed
  end

  defp normalize_string(nil, default), do: default
  defp normalize_string(value, default), do: normalize_string(to_string(value), default)

  defp normalize_boolean(value, _default) when is_boolean(value), do: value

  defp normalize_boolean(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp normalize_boolean(_value, default), do: default

  defp config_root do
    System.get_env("HIVEBEAM_CONFIG_ROOT") ||
      Path.join([System.user_home!(), ".config", "hivebeam"])
  end
end
