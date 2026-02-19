defmodule Hivebeam.Gateway.Config do
  @moduledoc false

  @default_bind "0.0.0.0:8080"
  @default_data_dir Path.join([System.user_home!(), ".config", "hivebeam", "gateway"])
  @default_max_events 50_000
  @default_reconnect_ms 2_000
  @default_approval_timeout_ms 120_000
  @default_sandbox_dangerously false

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

  @spec sandbox_dangerously_enabled?() :: boolean()
  def sandbox_dangerously_enabled? do
    parse_boolean(System.get_env("HIVEBEAM_GATEWAY_DANGEROUSLY"), @default_sandbox_dangerously)
  end

  @spec sandbox_default_root() :: String.t()
  def sandbox_default_root do
    root =
      case System.get_env("HIVEBEAM_GATEWAY_SANDBOX_DEFAULT_ROOT") do
        value when is_binary(value) ->
          value = String.trim(value)
          if(value == "", do: File.cwd!(), else: value)

        _ ->
          File.cwd!()
      end

    canonicalize_path!(root)
  end

  @spec sandbox_allowed_roots() :: [String.t()]
  def sandbox_allowed_roots do
    default_root = sandbox_default_root()

    roots =
      System.get_env("HIVEBEAM_GATEWAY_SANDBOX_ALLOWED_ROOTS")
      |> parse_path_list()
      |> normalize_root_list()
      |> case do
        [] -> [default_root]
        values -> values
      end
      |> ensure_default_root(default_root)

    roots
  end

  @spec normalize_session_cwd(term(), keyword()) ::
          {:ok,
           %{
             cwd: String.t(),
             sandbox_roots: [String.t()],
             sandbox_default_root: String.t(),
             dangerously: boolean()
           }}
          | {:error, term()}
  def normalize_session_cwd(raw_cwd, opts \\ []) do
    default_root = sandbox_default_root()

    roots =
      opts
      |> Keyword.get(:allowed_roots, sandbox_allowed_roots())
      |> normalize_root_list()
      |> case do
        [] -> [default_root]
        values -> ensure_default_root(values, default_root)
      end

    dangerously =
      opts
      |> Keyword.get(:dangerously, sandbox_dangerously_enabled?())
      |> parse_boolean(false)

    cwd =
      case normalize_path_value(raw_cwd) do
        nil -> default_root
        value -> value
      end

    with {:ok, canonical_cwd} <- canonicalize_path(cwd),
         :ok <- ensure_directory(canonical_cwd),
         :ok <- ensure_path_allowed(canonical_cwd, roots, dangerously: dangerously) do
      {:ok,
       %{
         cwd: canonical_cwd,
         sandbox_roots: roots,
         sandbox_default_root: default_root,
         dangerously: dangerously
       }}
    end
  end

  @spec ensure_path_allowed(term(), [String.t()], keyword()) :: :ok | {:error, term()}
  def ensure_path_allowed(path, roots, opts \\ []) do
    dangerously =
      opts
      |> Keyword.get(:dangerously, false)
      |> parse_boolean(false)

    with {:ok, canonical_path} <- canonicalize_path(path) do
      normalized_roots = normalize_root_list(roots)

      cond do
        dangerously ->
          :ok

        normalized_roots == [] ->
          {:error, {:sandbox_violation, %{path: canonical_path, allowed_roots: []}}}

        Enum.any?(normalized_roots, &path_inside_root?(canonical_path, &1)) ->
          :ok

        true ->
          {:error, {:sandbox_violation, %{path: canonical_path, allowed_roots: normalized_roots}}}
      end
    end
  end

  @spec canonicalize_path(term()) :: {:ok, String.t()} | {:error, :invalid_path}
  def canonicalize_path(path) when is_binary(path) do
    case normalize_path_value(path) do
      nil ->
        {:error, :invalid_path}

      value ->
        expanded = Path.expand(value)
        {:ok, canonicalize_non_existing_path(expanded)}
    end
  end

  def canonicalize_path(_path), do: {:error, :invalid_path}

  defp parse_pos_integer(nil, default), do: default

  defp parse_pos_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _ -> default
    end
  end

  defp parse_pos_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_pos_integer(_value, default), do: default

  defp normalize_path_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_path_value(_value), do: nil

  defp parse_path_list(nil), do: []

  defp parse_path_list(value) when is_binary(value) do
    separator = path_separator()

    value
    |> String.replace("\n", separator)
    |> String.split([separator, ",", ";"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_root_list(roots) when is_list(roots) do
    roots
    |> Enum.reduce([], fn root, acc ->
      case canonicalize_path(root) do
        {:ok, canonical_root} -> [canonical_root | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp normalize_root_list(root) when is_binary(root), do: normalize_root_list([root])
  defp normalize_root_list(_root), do: []

  defp ensure_default_root(roots, default_root) do
    if Enum.any?(roots, &path_inside_root?(default_root, &1)) do
      roots
    else
      [default_root | roots] |> Enum.uniq()
    end
  end

  defp path_inside_root?(path, root) do
    path_parts = Path.split(path)
    root_parts = Path.split(root)
    root_size = length(root_parts)

    length(path_parts) >= root_size and Enum.take(path_parts, root_size) == root_parts
  end

  defp ensure_directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, _} ->
        {:error, {:invalid_cwd, :not_directory}}

      {:error, _reason} ->
        {:error, {:invalid_cwd, :not_found}}
    end
  end

  defp canonicalize_path!(path) do
    case canonicalize_path(path) do
      {:ok, canonical_path} -> canonical_path
      _ -> Path.expand(to_string(path))
    end
  end

  defp canonicalize_non_existing_path(path) do
    case nearest_existing_ancestor(path, []) do
      {:ok, ancestor, suffix} ->
        ancestor_path = Path.expand(ancestor)

        suffix
        |> Enum.reduce(ancestor_path, fn segment, acc -> Path.join(acc, segment) end)
        |> Path.expand()

      :error ->
        path
    end
  end

  defp nearest_existing_ancestor(path, suffix) do
    if File.exists?(path) do
      {:ok, path, suffix}
    else
      parent = Path.dirname(path)

      if parent == path do
        :error
      else
        nearest_existing_ancestor(parent, [Path.basename(path) | suffix])
      end
    end
  end

  defp parse_boolean(value, _default) when is_boolean(value), do: value

  defp parse_boolean(value, default) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      "0" -> false
      "false" -> false
      "no" -> false
      "off" -> false
      "" -> default
      _ -> default
    end
  end

  defp parse_boolean(_value, default), do: default

  defp path_separator do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
  end
end
