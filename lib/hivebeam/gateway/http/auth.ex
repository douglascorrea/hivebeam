defmodule Hivebeam.Gateway.HTTP.Auth do
  @moduledoc false

  import Plug.Conn

  alias Hivebeam.Gateway.Config

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/healthz"} = conn, _opts), do: conn

  def call(conn, _opts) do
    case validate_authorization(get_req_header(conn, "authorization")) do
      :ok ->
        conn

      {:error, :missing_token_config} ->
        conn
        |> send_resp(500, "gateway token is not configured")
        |> halt()

      _ ->
        conn
        |> send_resp(401, "unauthorized")
        |> halt()
    end
  end

  @spec authorized_cowboy_req?(term()) :: :ok | {:error, term()}
  def authorized_cowboy_req?(req) do
    header = :cowboy_req.header("authorization", req)
    values = if is_binary(header), do: [header], else: []
    validate_authorization(values)
  end

  defp validate_authorization(values) when is_list(values) do
    with token when is_binary(token) <- Config.token(),
         {:ok, provided} <- bearer_token(values),
         true <- secure_compare(provided, token) do
      :ok
    else
      nil -> {:error, :missing_token_config}
      _ -> {:error, :unauthorized}
    end
  end

  defp bearer_token(values) do
    values
    |> Enum.find_value(fn value ->
      value = String.trim(value)

      case String.split(value, " ", parts: 2) do
        ["Bearer", token] when token != "" -> token
        _ -> nil
      end
    end)
    |> case do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :missing_bearer}
    end
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end
end
