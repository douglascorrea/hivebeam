defmodule Hivebeam.Gateway.Config do
  @moduledoc false

  @default_bind "0.0.0.0:8080"
  @default_data_dir Path.join([System.user_home!(), ".config", "hivebeam", "gateway"])
  @default_max_events 50_000
  @default_reconnect_ms 2_000
  @default_approval_timeout_ms 120_000

  @spec require_token!() :: :ok
  def require_token! do
    case token() do
      nil ->
        raise "HIVEBEAM_GATEWAY_TOKEN is required"

      _value ->
        :ok
    end
  end

  @spec bind() :: String.t()
  def bind do
    System.get_env("HIVEBEAM_GATEWAY_BIND", @default_bind)
    |> String.trim()
    |> case do
      "" -> @default_bind
      value -> value
    end
  end

  @spec bind_host() :: String.t()
  def bind_host do
    bind()
    |> String.split(":", parts: 2)
    |> List.first()
  end

  @spec bind_port() :: pos_integer()
  def bind_port do
    case bind() |> String.split(":", parts: 2) do
      [_host, port] -> parse_pos_integer(port, 8080)
      _ -> 8080
    end
  end

  @spec bind_ip() :: :inet.ip_address()
  def bind_ip do
    bind_host()
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      _ -> {0, 0, 0, 0}
    end
  end

  @spec token() :: String.t() | nil
  def token do
    case System.get_env("HIVEBEAM_GATEWAY_TOKEN") do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  @spec data_dir() :: String.t()
  def data_dir do
    case System.get_env("HIVEBEAM_GATEWAY_DATA_DIR") do
      value when is_binary(value) and value != "" -> value
      _ -> @default_data_dir
    end
  end

  @spec max_events_per_session() :: pos_integer()
  def max_events_per_session do
    parse_pos_integer(
      System.get_env("HIVEBEAM_GATEWAY_MAX_EVENTS_PER_SESSION"),
      @default_max_events
    )
  end

  @spec reconnect_ms() :: pos_integer()
  def reconnect_ms do
    parse_pos_integer(System.get_env("HIVEBEAM_GATEWAY_RECONNECT_MS"), @default_reconnect_ms)
  end

  @spec approval_timeout_ms() :: pos_integer()
  def approval_timeout_ms do
    parse_pos_integer(
      System.get_env("HIVEBEAM_GATEWAY_APPROVAL_TIMEOUT_MS"),
      @default_approval_timeout_ms
    )
  end

  defp parse_pos_integer(nil, default), do: default

  defp parse_pos_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _ -> default
    end
  end

  defp parse_pos_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_pos_integer(_value, default), do: default
end
