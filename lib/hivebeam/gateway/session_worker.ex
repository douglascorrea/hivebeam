defmodule Hivebeam.Gateway.SessionWorker do
  @moduledoc false
  use GenServer

  require Logger

  alias Hivebeam.ClaudeBridge
  alias Hivebeam.CodexBridge
  alias Hivebeam.CodexConfig
  alias Hivebeam.Gateway.Config
  alias Hivebeam.Gateway.EventLog
  alias Hivebeam.Gateway.SessionRouter
  alias Hivebeam.Gateway.Store

  @sync_interval_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    name = SessionRouter.worker_name(session_key)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    session_key = Keyword.fetch!(opts, :session_key)
    recovered? = Keyword.get(opts, :recovered?, false)

    with {:ok, session} <- Store.get_session(session_key) do
      provider = normalize_provider(Map.get(session, :provider, "codex"))

      state = %{
        session_key: session_key,
        bridge_name: SessionRouter.bridge_name(session_key),
        provider: provider,
        cwd: Map.get(session, :cwd, File.cwd!()),
        approval_mode: Map.get(session, :approval_mode, :ask),
        bridge_module: resolve_bridge_module(opts, provider),
        bridge_config: Keyword.get(opts, :bridge_config, %{}),
        queue: :queue.new(),
        in_flight: nil,
        pending_approvals: %{},
        connected: false,
        upstream_session_id: Map.get(session, :upstream_session_id),
        recovered?: recovered?,
        reconnect_ms: Config.reconnect_ms(),
        approval_timeout_ms: Config.approval_timeout_ms(),
        sync_timer_ref: nil
      }

      {:ok, state, {:continue, :bootstrap}}
    else
      _ -> {:stop, :session_not_found}
    end
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    state =
      state
      |> maybe_emit_recovered_event()
      |> ensure_bridge_started()
      |> schedule_sync()

    {:noreply, state}
  end

  @impl true
  def handle_call({:prompt, request_id, text, timeout_ms}, _from, state)
      when is_binary(request_id) and is_binary(text) and is_integer(timeout_ms) and timeout_ms > 0 do
    case Store.get_request(state.session_key, request_id) do
      {:ok, existing} ->
        {:reply,
         {:ok,
          %{
            accepted: true,
            existing: true,
            request_id: request_id,
            status: Map.get(existing, :status, "unknown"),
            last_seq: current_last_seq(state.session_key)
          }}, state}

      {:error, :not_found} ->
        record = %{
          status: "queued",
          text: text,
          timeout_ms: timeout_ms
        }

        with {:ok, _record} <- Store.put_request(state.session_key, request_id, record) do
          payload = %{request_id: request_id, timeout_ms: timeout_ms}
          state = append_and_broadcast(state, "prompt_enqueued", "gateway", payload)

          queue =
            :queue.in(%{request_id: request_id, text: text, timeout_ms: timeout_ms}, state.queue)

          state = %{state | queue: queue}
          state = maybe_start_next_prompt(state)

          {:reply,
           {:ok,
            %{
              accepted: true,
              request_id: request_id,
              queued_position: queue_len(queue),
              last_seq: current_last_seq(state.session_key)
            }}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:cancel, _from, state) do
    case state.in_flight do
      nil ->
        {:reply,
         {:ok,
          %{
            accepted: false,
            reason: "no_prompt_in_progress",
            last_seq: current_last_seq(state.session_key)
          }}, state}

      _in_flight ->
        reply = state.bridge_module.cancel_prompt(bridge_name: state.bridge_name)

        accepted = reply == :ok

        state =
          append_and_broadcast(state, "cancel_requested", "gateway", %{
            accepted: accepted,
            reason: inspect(reply)
          })

        {:reply, {:ok, %{accepted: accepted, last_seq: current_last_seq(state.session_key)}},
         state}
    end
  end

  def handle_call({:approve, approval_ref, decision}, _from, state)
      when is_binary(approval_ref) and is_binary(decision) do
    case Map.pop(state.pending_approvals, approval_ref) do
      {nil, _pending} ->
        {:reply, {:error, :approval_not_found}, state}

      {%{ref: ref, reply_to: reply_to, timer_ref: timer_ref}, pending} ->
        _ = Process.cancel_timer(timer_ref)
        decision_bool = decision in ["allow", "approved", "true", "yes"]
        send(reply_to, {:codex_tool_approval_reply, ref, decision_bool})

        state =
          state
          |> Map.put(:pending_approvals, pending)
          |> append_and_broadcast("approval_resolved", "gateway", %{
            approval_ref: approval_ref,
            decision: if(decision_bool, do: "allow", else: "deny")
          })

        {:reply, {:ok, %{accepted: true, last_seq: current_last_seq(state.session_key)}}, state}
    end
  end

  def handle_call(:close, _from, state) do
    stop_bridge(state)

    state = append_and_broadcast(state, "session_worker_stopped", "gateway", %{})
    {:stop, :normal, {:ok, %{closed: true, last_seq: current_last_seq(state.session_key)}}, state}
  end

  @impl true
  def handle_info({:codex_prompt_stream, payload}, state) when is_map(payload) do
    kind = stream_kind(payload)
    sanitized = sanitize_payload(payload)

    state = append_and_broadcast(state, kind, "upstream", sanitized)
    {:noreply, state}
  end

  def handle_info({:codex_tool_approval_request, payload}, state) when is_map(payload) do
    approval_ref = "apr_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    ref = Map.get(payload, :ref)
    reply_to = Map.get(payload, :reply_to)

    if is_reference(ref) and is_pid(reply_to) do
      timer_ref =
        Process.send_after(self(), {:approval_timeout, approval_ref}, state.approval_timeout_ms)

      pending =
        Map.put(state.pending_approvals, approval_ref, %{
          ref: ref,
          reply_to: reply_to,
          timer_ref: timer_ref
        })

      state =
        state
        |> Map.put(:pending_approvals, pending)
        |> append_and_broadcast("approval_requested", "gateway", %{
          approval_ref: approval_ref,
          request: sanitize_payload(Map.get(payload, :request, %{}))
        })

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:approval_timeout, approval_ref}, state) do
    case Map.pop(state.pending_approvals, approval_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{ref: ref, reply_to: reply_to}, pending} ->
        send(reply_to, {:codex_tool_approval_reply, ref, false})

        state =
          state
          |> Map.put(:pending_approvals, pending)
          |> append_and_broadcast("approval_timeout", "gateway", %{approval_ref: approval_ref})

        {:noreply, state}
    end
  end

  def handle_info(:sync_status, state) do
    state =
      state
      |> sync_bridge_status()
      |> maybe_start_next_prompt()
      |> schedule_sync()

    {:noreply, state}
  end

  def handle_info({task_ref, response}, %{in_flight: %{task_ref: task_ref} = in_flight} = state) do
    Process.demonitor(task_ref, [:flush])

    state =
      case response do
        {:ok, result} ->
          _ =
            Store.update_request(state.session_key, in_flight.request_id, %{
              status: "completed",
              result: result,
              completed_at: now_iso()
            })

          append_and_broadcast(state, "prompt_completed", "gateway", %{
            request_id: in_flight.request_id,
            stop_reason: Map.get(result, :stop_reason) || Map.get(result, "stop_reason"),
            session_id: Map.get(result, :session_id) || Map.get(result, "session_id")
          })

        {:error, reason} ->
          _ =
            Store.update_request(state.session_key, in_flight.request_id, %{
              status: "failed",
              error: inspect(reason),
              completed_at: now_iso()
            })

          append_and_broadcast(state, "prompt_failed", "gateway", %{
            request_id: in_flight.request_id,
            reason: inspect(reason)
          })
      end

    state =
      state
      |> Map.put(:in_flight, nil)
      |> persist_session(%{in_flight: false})
      |> maybe_start_next_prompt()

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{in_flight: %{task_ref: ref} = in_flight} = state
      ) do
    state =
      state
      |> append_and_broadcast("prompt_failed", "gateway", %{
        request_id: in_flight.request_id,
        reason: inspect({:prompt_task_down, reason})
      })
      |> Map.put(:in_flight, nil)
      |> persist_session(%{in_flight: false})
      |> maybe_start_next_prompt()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_bridge(state)
    :ok
  end

  defp maybe_emit_recovered_event(%{recovered?: true} = state) do
    append_and_broadcast(state, "session_recovered", "gateway", %{})
  end

  defp maybe_emit_recovered_event(state), do: state

  defp ensure_bridge_started(state) do
    provider = state.provider

    case CodexConfig.acp_command(provider) do
      {:ok, command} ->
        config = %{
          acp_provider: provider,
          acp_command: command,
          tool_cwd: state.cwd,
          approval_mode: state.approval_mode,
          approval_timeout_ms: state.approval_timeout_ms
        }

        config = Map.merge(config, state.bridge_config)

        case state.bridge_module.start_link(name: state.bridge_name, config: config) do
          {:ok, _pid} ->
            state

          {:error, {:already_started, _pid}} ->
            state

          {:error, reason} ->
            Logger.warning(
              "could not start session bridge #{state.session_key}: #{inspect(reason)}"
            )

            append_and_broadcast(state, "upstream_start_failed", "gateway", %{
              reason: inspect(reason)
            })
        end

      {:error, reason} ->
        append_and_broadcast(state, "upstream_command_invalid", "gateway", %{
          reason: inspect(reason)
        })
    end
  end

  defp stop_bridge(state) do
    case GenServer.whereis(state.bridge_name) do
      nil -> :ok
      pid when is_pid(pid) -> Process.exit(pid, :normal)
    end
  end

  defp schedule_sync(state) do
    if is_reference(state.sync_timer_ref) do
      _ = Process.cancel_timer(state.sync_timer_ref)
    end

    ref = Process.send_after(self(), :sync_status, @sync_interval_ms)
    %{state | sync_timer_ref: ref}
  end

  defp sync_bridge_status(state) do
    if status_poll_blocked?(state) do
      state
    else
      case state.bridge_module.status(state.bridge_name) do
        {:ok, status} ->
          connected = status.connected == true
          upstream_session_id = status.session_id
          in_flight = status.in_flight_prompt == true or not is_nil(state.in_flight)

          state =
            state
            |> maybe_emit_connection_events(connected, upstream_session_id)
            |> persist_session(%{
              status: if(connected, do: "connected", else: "degraded"),
              connected: connected,
              in_flight: in_flight,
              upstream_session_id: upstream_session_id,
              approval_mode: Map.get(status, :approval_mode, state.approval_mode)
            })

          %{state | connected: connected, upstream_session_id: upstream_session_id}

        {:error, reason} ->
          state
          |> append_and_broadcast("upstream_status_error", "gateway", %{reason: inspect(reason)})
          |> persist_session(%{status: "degraded", connected: false})
          |> Map.put(:connected, false)
      end
    end
  end

  defp status_poll_blocked?(state) do
    not is_nil(state.in_flight) or map_size(state.pending_approvals) > 0
  end

  defp maybe_emit_connection_events(state, connected, upstream_session_id) do
    cond do
      connected and not state.connected ->
        append_and_broadcast(state, "upstream_connected", "gateway", %{
          upstream_session_id: upstream_session_id
        })

      not connected and state.connected ->
        append_and_broadcast(state, "upstream_disconnected", "gateway", %{})

      connected and is_binary(state.upstream_session_id) and is_binary(upstream_session_id) and
          state.upstream_session_id != upstream_session_id ->
        append_and_broadcast(state, "upstream_session_rotated", "gateway", %{
          from: state.upstream_session_id,
          to: upstream_session_id
        })

      true ->
        state
    end
  end

  defp maybe_start_next_prompt(%{in_flight: nil, connected: true} = state) do
    case :queue.out(state.queue) do
      {{:value, next}, queue} ->
        _ =
          Store.update_request(state.session_key, next.request_id, %{
            status: "running",
            started_at: now_iso()
          })

        state =
          append_and_broadcast(state, "prompt_started", "gateway", %{request_id: next.request_id})

        owner = self()

        task =
          Task.async(fn ->
            state.bridge_module.prompt(next.text,
              bridge_name: state.bridge_name,
              timeout: next.timeout_ms,
              stream_to: owner,
              approval_to: owner,
              approval_mode: state.approval_mode
            )
          end)

        in_flight = %{request_id: next.request_id, task_ref: task.ref, task_pid: task.pid}

        state
        |> Map.put(:queue, queue)
        |> Map.put(:in_flight, in_flight)
        |> persist_session(%{in_flight: true})

      {:empty, _queue} ->
        state
    end
  end

  defp maybe_start_next_prompt(state), do: state

  defp append_and_broadcast(state, kind, source, payload) do
    sanitized_payload = sanitize_payload(payload)

    case EventLog.append(state.session_key, kind, source, sanitized_payload) do
      {:ok, event} ->
        _ = SessionRouter.broadcast_event(state.session_key, event)
        state

      {:error, reason} ->
        Logger.warning("event append failed for #{state.session_key}: #{inspect(reason)}")
        state
    end
  end

  defp persist_session(state, attrs) do
    case Store.get_session(state.session_key) do
      {:ok, session} ->
        _ =
          session
          |> Map.merge(attrs)
          |> Map.put(:updated_at, now_iso())
          |> Store.upsert_session()

        state

      _ ->
        state
    end
  end

  defp current_last_seq(session_key) do
    case Store.get_session(session_key) do
      {:ok, session} -> Map.get(session, :last_seq, 0)
      _ -> 0
    end
  end

  defp stream_kind(payload) do
    case Map.get(payload, :event) || Map.get(payload, "event") do
      event when event in [:start, "start"] -> "stream_start"
      event when event in [:update, "update"] -> "stream_update"
      event when event in [:status, "status"] -> "stream_status"
      event when event in [:done, "done"] -> "stream_done"
      event when event in [:error, "error"] -> "stream_error"
      _ -> "stream_event"
    end
  end

  defp sanitize_payload(payload) when is_map(payload) do
    payload
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = normalize_key(key)

      if key in ["reply_to", "from", "task_pid", "task_ref"] do
        acc
      else
        Map.put(acc, key, sanitize_payload(value))
      end
    end)
  end

  defp sanitize_payload(value) when is_list(value), do: Enum.map(value, &sanitize_payload/1)

  defp sanitize_payload(value) when is_pid(value), do: inspect(value)
  defp sanitize_payload(value) when is_reference(value), do: inspect(value)

  defp sanitize_payload(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&sanitize_payload/1)

  defp sanitize_payload(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)

  defp normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "codex"
      value -> value
    end
  end

  defp normalize_provider(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> normalize_provider()
  end

  defp normalize_provider(_), do: "codex"

  defp resolve_bridge_module(opts, provider) do
    explicit_bridge = Keyword.get(opts, :bridge_module)
    global_bridge = Application.get_env(:hivebeam, :gateway_bridge_module)
    provider_bridges = Application.get_env(:hivebeam, :gateway_bridge_modules, %{})

    cond do
      is_atom(explicit_bridge) and not is_nil(explicit_bridge) ->
        explicit_bridge

      is_atom(global_bridge) and not is_nil(global_bridge) ->
        global_bridge

      module = bridge_module_from_map(provider_bridges, provider) ->
        module

      true ->
        default_bridge_module(provider)
    end
  end

  defp bridge_module_from_map(map, provider) when is_map(map) do
    value =
      Map.get(map, provider) ||
        Enum.find_value(map, fn
          {key, module} when is_atom(key) and is_atom(module) ->
            if Atom.to_string(key) == provider, do: module

          _ ->
            nil
        end)

    if is_atom(value), do: value, else: nil
  end

  defp bridge_module_from_map(_map, _provider), do: nil

  defp default_bridge_module("claude"), do: ClaudeBridge
  defp default_bridge_module("codex"), do: CodexBridge
  defp default_bridge_module(_), do: CodexBridge

  defp queue_len(queue), do: :queue.len(queue)

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end
end
