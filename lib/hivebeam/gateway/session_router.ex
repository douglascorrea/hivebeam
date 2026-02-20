defmodule Hivebeam.Gateway.SessionRouter do
  @moduledoc false

  alias Hivebeam.Gateway.EventLog
  alias Hivebeam.Gateway.PolicyGate
  alias Hivebeam.Gateway.SLO
  alias Hivebeam.Gateway.SessionSupervisor
  alias Hivebeam.Gateway.SessionWorker
  alias Hivebeam.Gateway.Store

  @worker_registry Hivebeam.Gateway.WorkerRegistry
  @event_registry Hivebeam.Gateway.EventRegistry
  @worker_call_timeout_ms 30_000

  @spec create_session(map()) :: {:ok, map()} | {:error, term()}
  def create_session(attrs \\ %{}) when is_map(attrs) do
    started_at_ms = System.monotonic_time(:millisecond)
    result = do_create_session(attrs)

    duration_ms = System.monotonic_time(:millisecond) - started_at_ms
    :ok = SLO.record_session_create_duration(duration_ms)

    result
  end

  defp do_create_session(attrs) do
    key =
      attrs
      |> Map.get("client_session_ref")
      |> Kernel.||(Map.get(attrs, :client_session_ref))
      |> session_key()

    case Store.get_session(key) do
      {:ok, existing} ->
        if closed_session?(existing) do
          {:ok, existing}
        else
          with {:ok, _pid} <- ensure_worker(key, recovered?: true) do
            {:ok, existing}
          end
        end

      {:error, :not_found} ->
        with {:ok, policy} <- PolicyGate.evaluate_session_create(attrs),
             now <- now_iso(),
             session <- %{
               gateway_session_key: key,
               provider: policy.provider,
               cwd: policy.sandbox.cwd,
               approval_mode: policy.approval_mode,
               dangerously: policy.sandbox.dangerously,
               sandbox_default_root: policy.sandbox.sandbox_default_root,
               sandbox_roots: policy.sandbox.sandbox_roots,
               status: "creating",
               connected: false,
               in_flight: false,
               upstream_session_id: nil,
               created_at: now,
               updated_at: now,
               last_seq: 0
             },
             {:ok, _persisted_session} <- Store.upsert_session(session),
             {:ok, _event} <-
               EventLog.append(key, "session_created", "gateway", %{
                 provider: policy.provider,
                 dangerously: policy.sandbox.dangerously
               }),
             :ok <- emit_policy_decision(key, policy.audit),
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
    with {:ok, session} <- Store.get_session(gateway_session_key),
         :ok <- ensure_session_open(session),
         {:ok, policy} <- PolicyGate.evaluate_prompt(session, request_id, text),
         :ok <- emit_policy_decision(gateway_session_key, policy.audit),
         {:ok, pid} <- ensure_worker(gateway_session_key, recovered?: true) do
      timeout_ms = normalize_timeout(timeout_ms)
      safe_worker_call(pid, {:prompt, request_id, policy.text, timeout_ms}, timeout_ms + 5_000)
    else
      {:error, {:policy_denied, %{audit: audit} = details}} ->
        _ = emit_policy_decision(gateway_session_key, audit)
        {:error, {:policy_denied, Map.delete(details, :audit)}}

      error ->
        error
    end
  end

  @spec cancel(String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(gateway_session_key) when is_binary(gateway_session_key) do
    with {:ok, session} <- Store.get_session(gateway_session_key),
         :ok <- ensure_session_open(session),
         {:ok, pid} <- ensure_worker(gateway_session_key, recovered?: true) do
      safe_worker_call(pid, :cancel, @worker_call_timeout_ms)
    end
  end

  @spec approve(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def approve(gateway_session_key, approval_ref, decision)
      when is_binary(gateway_session_key) and is_binary(approval_ref) and is_binary(decision) do
    with {:ok, session} <- Store.get_session(gateway_session_key),
         :ok <- ensure_session_open(session),
         {:ok, pid} <- ensure_worker(gateway_session_key, recovered?: true) do
      safe_worker_call(pid, {:approve, approval_ref, decision}, @worker_call_timeout_ms)
    end
  end

  @spec close(String.t()) :: {:ok, map()} | {:error, term()}
  def close(gateway_session_key) when is_binary(gateway_session_key) do
    with {:ok, session} <- Store.get_session(gateway_session_key) do
      if closed_session?(session) do
        {:ok, session}
      else
        maybe_close_worker(gateway_session_key)
        _ = EventLog.append(gateway_session_key, "session_closed", "gateway", %{})
        Store.close_session(gateway_session_key)
      end
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
    allow_closed? = Keyword.get(opts, :allow_closed?, false)

    with {:ok, session} <- Store.get_session(gateway_session_key),
         :ok <- ensure_session_open(session, allow_closed?: allow_closed?) do
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

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout(_value), do: 120_000

  defp maybe_put_bridge_module(opts, nil), do: opts

  defp maybe_put_bridge_module(opts, module) when is_atom(module),
    do: Keyword.put(opts, :bridge_module, module)

  defp ensure_session_open(session, opts \\ []) do
    allow_closed? = Keyword.get(opts, :allow_closed?, false)

    if closed_session?(session) and not allow_closed? do
      {:error, :session_closed}
    else
      :ok
    end
  end

  defp closed_session?(session) when is_map(session), do: Map.get(session, :status) == "closed"
  defp closed_session?(_session), do: false

  defp maybe_close_worker(gateway_session_key) do
    case Registry.lookup(@worker_registry, {:session_worker, gateway_session_key}) do
      [{pid, _}] when is_pid(pid) ->
        _ = safe_worker_call(pid, :close, @worker_call_timeout_ms)
        :ok

      _ ->
        :ok
    end
  end

  defp emit_policy_decision(_gateway_session_key, nil), do: :ok

  defp emit_policy_decision(gateway_session_key, audit) when is_map(audit) do
    if policy_audit_enabled?(audit) do
      _ = EventLog.append(gateway_session_key, "policy_decision", "policy", audit)
    end

    :ok
  end

  defp policy_audit_enabled?(audit) when is_map(audit) do
    Map.get(audit, :audit_enabled, Map.get(audit, "audit_enabled", true))
  end

  defp safe_worker_call(pid, message, timeout_ms) when is_pid(pid) and is_integer(timeout_ms) do
    try do
      GenServer.call(pid, message, timeout_ms)
    catch
      :exit, reason ->
        {:error, {:worker_call_exit, reason}}
    end
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end
end
