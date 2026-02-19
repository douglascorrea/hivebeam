defmodule Hivebeam.Gateway.SessionRouter do
  @moduledoc false

  alias Hivebeam.Gateway.EventLog
  alias Hivebeam.Gateway.SessionSupervisor
  alias Hivebeam.Gateway.SessionWorker
  alias Hivebeam.Gateway.Store

  @worker_registry Hivebeam.Gateway.WorkerRegistry
  @event_registry Hivebeam.Gateway.EventRegistry

  @spec create_session(map()) :: {:ok, map()} | {:error, term()}
  def create_session(attrs \\ %{}) when is_map(attrs) do
    provider = normalize_provider(Map.get(attrs, "provider") || Map.get(attrs, :provider))
    cwd = normalize_cwd(Map.get(attrs, "cwd") || Map.get(attrs, :cwd))

    approval_mode =
      attrs
      |> Map.get("approval_mode")
      |> Kernel.||(Map.get(attrs, :approval_mode))
      |> normalize_approval_mode()

    key =
      attrs
      |> Map.get("client_session_ref")
      |> Kernel.||(Map.get(attrs, :client_session_ref))
      |> session_key()

    case Store.get_session(key) do
      {:ok, existing} ->
        with {:ok, _pid} <- ensure_worker(key, recovered?: true) do
          {:ok, existing}
        end

      {:error, :not_found} ->
        now = now_iso()

        session = %{
          gateway_session_key: key,
          provider: provider,
          cwd: cwd,
          approval_mode: approval_mode,
          status: "creating",
          connected: false,
          in_flight: false,
          upstream_session_id: nil,
          created_at: now,
          updated_at: now,
          last_seq: 0
        }

        with {:ok, _persisted_session} <- Store.upsert_session(session),
             {:ok, _event} <-
               EventLog.append(key, "session_created", "gateway", %{provider: provider}),
             {:ok, _pid} <- ensure_worker(key, recovered?: false),
             {:ok, updated} <- Store.get_session(key) do
          {:ok, updated}
        end

      error ->
        error
    end
  end

  @spec get_session(String.t()) :: {:ok, map()} | {:error, term()}
  def get_session(gateway_session_key) when is_binary(gateway_session_key) do
    Store.get_session(gateway_session_key)
  end

  @spec prompt(String.t(), String.t(), String.t(), pos_integer() | nil) ::
          {:ok, map()} | {:error, term()}
  def prompt(gateway_session_key, request_id, text, timeout_ms \\ nil)
      when is_binary(gateway_session_key) and is_binary(request_id) and is_binary(text) do
    with {:ok, _session} <- Store.get_session(gateway_session_key),
         {:ok, pid} <- ensure_worker(gateway_session_key, recovered?: true) do
      timeout_ms = normalize_timeout(timeout_ms)
      GenServer.call(pid, {:prompt, request_id, text, timeout_ms}, timeout_ms + 5_000)
    end
  end

  @spec cancel(String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(gateway_session_key) when is_binary(gateway_session_key) do
    with {:ok, _session} <- Store.get_session(gateway_session_key),
         {:ok, pid} <- ensure_worker(gateway_session_key, recovered?: true) do
      GenServer.call(pid, :cancel)
    end
  end

  @spec approve(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def approve(gateway_session_key, approval_ref, decision)
      when is_binary(gateway_session_key) and is_binary(approval_ref) and is_binary(decision) do
    with {:ok, _session} <- Store.get_session(gateway_session_key),
         {:ok, pid} <- ensure_worker(gateway_session_key, recovered?: true) do
      GenServer.call(pid, {:approve, approval_ref, decision})
    end
  end

  @spec close(String.t()) :: {:ok, map()} | {:error, term()}
  def close(gateway_session_key) when is_binary(gateway_session_key) do
    with {:ok, _session} <- Store.get_session(gateway_session_key),
         {:ok, pid} <- ensure_worker(gateway_session_key, recovered?: true) do
      _ = GenServer.call(pid, :close)
      _ = EventLog.append(gateway_session_key, "session_closed", "gateway", %{})
      Store.close_session(gateway_session_key)
    end
  end

  @spec events(String.t(), integer(), pos_integer()) ::
          {:ok, %{events: [map()], next_after_seq: integer(), has_more: boolean()}}
          | {:error, term()}
  def events(gateway_session_key, after_seq, limit)
      when is_binary(gateway_session_key) and is_integer(after_seq) and is_integer(limit) and
             limit > 0 do
    EventLog.replay(gateway_session_key, after_seq, limit)
  end

  @spec subscribe(String.t(), pid()) :: {:ok, reference()} | {:error, term()}
  def subscribe(gateway_session_key, subscriber \\ self())
      when is_binary(gateway_session_key) and is_pid(subscriber) do
    case Registry.register(@event_registry, {:session_events, gateway_session_key}, %{}) do
      {:ok, ref} -> {:ok, ref}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(gateway_session_key) when is_binary(gateway_session_key) do
    Registry.unregister(@event_registry, {:session_events, gateway_session_key})
    :ok
  end

  @spec broadcast_event(String.t(), map()) :: :ok
  def broadcast_event(gateway_session_key, event)
      when is_binary(gateway_session_key) and is_map(event) do
    Registry.dispatch(@event_registry, {:session_events, gateway_session_key}, fn entries ->
      Enum.each(entries, fn {pid, _meta} ->
        send(pid, {:gateway_event, event})
      end)
    end)

    :ok
  end

  @spec worker_name(String.t()) :: GenServer.name()
  def worker_name(gateway_session_key) when is_binary(gateway_session_key) do
    {:via, Registry, {@worker_registry, {:session_worker, gateway_session_key}}}
  end

  @spec bridge_name(String.t()) :: GenServer.name()
  def bridge_name(gateway_session_key) when is_binary(gateway_session_key) do
    {:via, Registry, {@worker_registry, {:session_bridge, gateway_session_key}}}
  end

  @spec ensure_worker(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_worker(gateway_session_key, opts \\ []) when is_binary(gateway_session_key) do
    case Registry.lookup(@worker_registry, {:session_worker, gateway_session_key}) do
      [{pid, _value}] when is_pid(pid) ->
        {:ok, pid}

      _ ->
        recovered? = Keyword.get(opts, :recovered?, false)
        bridge_module = Application.get_env(:hivebeam, :gateway_bridge_module)
        bridge_config = Application.get_env(:hivebeam, :gateway_bridge_config, %{})

        worker_args =
          [session_key: gateway_session_key, recovered?: recovered?]
          |> maybe_put_bridge_module(bridge_module)
          |> Keyword.put(:bridge_config, bridge_config)

        case DynamicSupervisor.start_child(
               SessionSupervisor,
               {SessionWorker, worker_args}
             ) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, {:shutdown, {:failed_to_start_child, _child, {:already_started, pid}}}} ->
            {:ok, pid}

          {:error, reason} ->
            case Registry.lookup(@worker_registry, {:session_worker, gateway_session_key}) do
              [{pid, _value}] when is_pid(pid) -> {:ok, pid}
              _ -> {:error, reason}
            end
        end
    end
  end

  @spec generate_session_key() :: String.t()
  def generate_session_key do
    "hbs_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp session_key(nil), do: generate_session_key()

  defp session_key(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      generate_session_key()
    else
      hash = :crypto.hash(:sha256, trimmed) |> Base.encode16(case: :lower)
      "hbs_" <> binary_part(hash, 0, 32)
    end
  end

  defp session_key(_), do: generate_session_key()

  defp normalize_provider(nil), do: "codex"

  defp normalize_provider(provider) do
    provider
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "codex"
      value -> value
    end
  end

  defp normalize_cwd(nil), do: File.cwd!()

  defp normalize_cwd(value) when is_binary(value) do
    case String.trim(value) do
      "" -> File.cwd!()
      path -> Path.expand(path)
    end
  end

  defp normalize_cwd(_), do: File.cwd!()

  defp normalize_approval_mode(mode) do
    case mode do
      :allow -> :allow
      :deny -> :deny
      "allow" -> :allow
      "deny" -> :deny
      _ -> :ask
    end
  end

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout(_value), do: 120_000

  defp maybe_put_bridge_module(opts, nil), do: opts

  defp maybe_put_bridge_module(opts, module) when is_atom(module),
    do: Keyword.put(opts, :bridge_module, module)

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end
end
