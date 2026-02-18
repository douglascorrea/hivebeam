defmodule Hivebeam.UI.Preferences do
  @moduledoc false

  alias Hivebeam.TomlLite

  @spec path() :: String.t()
  def path do
    System.get_env("HIVEBEAM_UI_PATH") || Path.join([config_root(), "ui.toml"])
  end

  @spec defaults() :: map()
  def defaults do
    %{
      "layout_mode" => "auto",
      "left_pane" => true,
      "right_pane" => true,
      "auto_layout" => true
    }
  end

  @spec load() :: map()
  def load do
    defaults = defaults()

    parsed =
      if mix_test_env?() and is_nil(System.get_env("HIVEBEAM_UI_PATH")) do
        %{}
      else
        case File.read(path()) do
          {:ok, raw} ->
            case TomlLite.decode(raw) do
              {:ok, decoded} when is_map(decoded) -> decoded
              _ -> %{}
            end

          _ ->
            %{}
        end
      end

    defaults
    |> Map.merge(parsed)
    |> normalize()
  end

  @spec save(map()) :: :ok | {:error, term()}
  def save(prefs) when is_map(prefs) do
    if persist_enabled?() do
      with :ok <- File.mkdir_p(config_root()) do
        prefs
        |> Map.merge(defaults(), fn _key, incoming, _default -> incoming end)
        |> normalize()
        |> TomlLite.encode()
        |> then(&File.write(path(), &1))
      end
    else
      :ok
    end
  end

  defp normalize(prefs) do
    %{
      "layout_mode" => normalize_layout(Map.get(prefs, "layout_mode")),
      "left_pane" => normalize_bool(Map.get(prefs, "left_pane"), true),
      "right_pane" => normalize_bool(Map.get(prefs, "right_pane"), true),
      "auto_layout" => normalize_bool(Map.get(prefs, "auto_layout"), true)
    }
  end

  defp normalize_layout(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "full" -> "full"
      "focus" -> "focus"
      "compact" -> "compact"
      _ -> "auto"
    end
  end

  defp normalize_layout(value) when is_atom(value), do: normalize_layout(Atom.to_string(value))
  defp normalize_layout(_), do: "auto"

  defp normalize_bool(value, _default) when is_boolean(value), do: value

  defp normalize_bool(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp normalize_bool(_value, default), do: default

  defp config_root do
    System.get_env("HIVEBEAM_CONFIG_ROOT") ||
      Path.join([System.user_home!(), ".config", "hivebeam"])
  end

  defp persist_enabled? do
    case System.get_env("HIVEBEAM_PERSIST_UI_PREFS") do
      "0" -> false
      "false" -> false
      _ -> not mix_test_env?()
    end
  end

  defp mix_test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end
