defmodule Hivebeam.AgentBridge do
  @moduledoc false
  use GenServer

  require Logger

  alias Hivebeam.CodexConfig
  alias Hivebeam.CodexStream

  @type status :: :connecting | :connected | :degraded
  @type approval_mode :: :ask | :allow | :deny

  @default_approval_timeout_ms 120_000
  @default_provider "codex"

  @spec start_link(keyword(), keyword()) :: GenServer.on_start()
  def start_link(opts, defaults \\ []) do
    default_bridge_name =
      Keyword.get(defaults, :default_bridge_name, CodexConfig.bridge_name(@default_provider))

    name = Keyword.get(opts, :name, default_bridge_name)
    opts = Keyword.put(opts, :agent_bridge_defaults, defaults)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    defaults = Keyword.get(opts, :agent_bridge_defaults, [])
    config = Keyword.get(opts, :config, %{})

    acp_client_module =
      Keyword.get(
        opts,
        :acp_client_module,
        Keyword.get(opts, :acpex_module, Hivebeam.Acp.Adapter)
      )

    connection_module = Keyword.get(opts, :connection_module, Hivebeam.Acp.JsonRpcConnection)

    default_provider =
      defaults
      |> Keyword.get(:default_provider, @default_provider)
      |> normalize_provider()

    acp_provider = normalize_provider(Map.get(config, :acp_provider, default_provider))

    default_bridge_name =
      Keyword.get(defaults, :default_bridge_name, CodexConfig.bridge_name(default_provider))

    bridge_name = Keyword.get(opts, :name, Map.get(config, :bridge_name, default_bridge_name))

    default_acp_command =
      Keyword.get(defaults, :default_acp_command, CodexConfig.acp_command(default_provider))

    {agent_path, agent_args, command_error} =
      case resolve_command(Map.get(config, :acp_command, default_acp_command)) do
        {:ok, {path, args}} -> {path, args, nil}
        {:error, reason} -> {nil, [], reason}
      end

    default_approval_mode =
      config
      |> Map.get(:approval_mode, :ask)
      |> normalize_approval_mode(:ask)

    tool_cwd = Map.get(config, :tool_cwd, File.cwd!())

    state = %{
      acp_client_module: acp_client_module,
      connection_module: connection_module,
      acp_provider: acp_provider,
      bridge_name: bridge_name,
      agent_path: agent_path,
      agent_args: agent_args,
      conn_pid: nil,
      conn_monitor_ref: nil,
      session_id: nil,
      status: :connecting,
      last_error: command_error,
      in_flight_prompt: nil,
      prompt_updates: empty_updates(),
      last_prompt_result: nil,
      connect_timeout_ms: Map.get(config, :connect_timeout_ms, CodexConfig.connect_timeout_ms()),
      prompt_timeout_ms: Map.get(config, :prompt_timeout_ms, CodexConfig.prompt_timeout_ms()),
      reconnect_ms: Map.get(config, :reconnect_ms, CodexConfig.reconnect_ms()),
      reconnect_timer_ref: nil,
      tool_cwd: tool_cwd,
      sandbox_roots: Map.get(config, :sandbox_roots, [tool_cwd]) |> List.wrap(),
      sandbox_default_root: Map.get(config, :sandbox_default_root, tool_cwd),
      dangerously: normalize_dangerously(Map.get(config, :dangerously, false)),
      default_approval_mode: default_approval_mode,
      approval_timeout_ms: Map.get(config, :approval_timeout_ms, @default_approval_timeout_ms),
      enforced_provider_mode: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, connect_if_possible(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    response = %{
      node: Node.self(),
      node_alive: Node.alive?(),
      connected_nodes: Node.list(),
      bridge_name: state.bridge_name,
      status: state.status,
      connected: state.status == :connected,
      acp_provider: state.acp_provider,
      session_id: state.session_id,
      connection_pid: state.conn_pid,
      in_flight_prompt: not is_nil(state.in_flight_prompt),
      last_error: state.last_error,
      last_prompt_result: state.last_prompt_result,
      approval_mode: current_approval_mode(state),
      enforced_provider_mode: state.enforced_provider_mode
    }

    {:reply, {:ok, response}, state}
  end

  def handle_call({:tool_approval, request}, _from, state) when is_map(request) do
    {:reply, approve_tool_request(state, request), state}
  end

  def handle_call(:cancel_prompt, _from, state) do
    cond do
      state.status != :connected or is_nil(state.conn_pid) or is_nil(state.session_id) ->
        {:reply, {:error, {:bridge_not_connected, state.last_error}}, state}

      state.in_flight_prompt == nil ->
        {:reply, {:error, :no_prompt_in_progress}, state}

      true ->
        payload = %{"sessionId" => state.session_id}
        state.connection_module.send_notification(state.conn_pid, "session/cancel", payload)

        notify_prompt_stream(state, %{
          event: :status,
          node: Node.self(),
          bridge_name: state.bridge_name,
          session_id: state.session_id,
          message: "cancel_requested"
        })

        {:reply, :ok, state}
    end
  end

  def handle_call({:prompt, prompt, opts}, from, state) when is_binary(prompt) do
    cond do
      state.status != :connected or is_nil(state.conn_pid) or is_nil(state.session_id) ->
        {:reply, {:error, {:bridge_not_connected, state.last_error}}, state}

      state.in_flight_prompt != nil ->
        {:reply, {:error, :prompt_in_progress}, state}

      true ->
        timeout_ms = normalize_timeout_ms(Keyword.get(opts, :timeout), state.prompt_timeout_ms)
        payload = prompt_payload(state.session_id, prompt)

        stream_targets = extract_stream_targets(opts)

        in_flight = %{
          from: from,
          timeout_ms: timeout_ms,
          started_at: System.monotonic_time(:millisecond),
          stream_targets: stream_targets,
          approval_to: normalize_approval_target(opts),
          approval_mode:
            normalize_approval_mode(
              Keyword.get(opts, :approval_mode),
              state.default_approval_mode
            )
        }

        task =
          Task.async(fn ->
            state.connection_module.send_request(
              state.conn_pid,
              "session/prompt",
              payload,
              timeout_ms
            )
          end)

        in_flight = Map.merge(in_flight, %{task_ref: task.ref, task_pid: task.pid})

        notify_stream_targets(stream_targets, %{
          event: :start,
          node: Node.self(),
          bridge_name: state.bridge_name,
          session_id: state.session_id
        })

        {:noreply, %{state | in_flight_prompt: in_flight, prompt_updates: empty_updates()}}
    end
  end

  @impl true
  def handle_info({:acp_session_update, %{session_id: session_id, update: update}}, state) do
    if should_capture_update?(state, session_id) do
      notify_prompt_stream(state, %{
        event: :update,
        node: Node.self(),
        bridge_name: state.bridge_name,
        session_id: session_id,
        update: update
      })

      {:noreply, %{state | prompt_updates: collect_update(state.prompt_updates, update)}}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {task_ref, response},
        %{in_flight_prompt: %{task_ref: task_ref} = in_flight} = state
      ) do
    Process.demonitor(task_ref, [:flush])
    reply = normalize_prompt_response(response, state.prompt_updates, state.session_id)

    notify_stream_targets(in_flight.stream_targets, %{
      event: :done,
      node: Node.self(),
      bridge_name: state.bridge_name,
      session_id: state.session_id,
      reply: reply
    })

    GenServer.reply(in_flight.from, reply)

    {:noreply,
     %{
       state
       | in_flight_prompt: nil,
         prompt_updates: empty_updates(),
         last_prompt_result: wrap_last_prompt_result(reply)
     }}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{in_flight_prompt: %{task_ref: ref} = in_flight} = state
      ) do
    notify_stream_targets(in_flight.stream_targets, %{
      event: :error,
      node: Node.self(),
      bridge_name: state.bridge_name,
      session_id: state.session_id,
      reason: {:prompt_task_down, reason}
    })

    GenServer.reply(in_flight.from, {:error, {:prompt_task_down, reason}})
    {:noreply, %{state | in_flight_prompt: nil, prompt_updates: empty_updates()}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_monitor_ref: ref} = state) do
    Logger.warning(
      "#{provider_title(state.acp_provider)} ACP connection dropped: #{inspect(reason)}"
    )

    state
    |> mark_disconnected({:connection_down, reason})
    |> maybe_reply_prompt_error({:connection_down, reason})
    |> schedule_reconnect()
    |> then(&{:noreply, &1})
  end

  def handle_info(:retry_connect, state) do
    next_state =
      state
      |> Map.put(:reconnect_timer_ref, nil)
      |> Map.put(:status, :connecting)
      |> connect_if_possible()

    {:noreply, next_state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @spec prompt_payload(String.t(), String.t()) :: map()
  defp prompt_payload(session_id, prompt) do
    %{
      "sessionId" => session_id,
      "prompt" => [
        %{"type" => "text", "text" => prompt}
      ]
    }
  end

  defp should_capture_update?(state, session_id) do
    state.in_flight_prompt != nil and state.session_id == session_id
  end

  defp collect_update(updates, update) do
    kind = stream_update_kind(update)

    cond do
      kind == "agent_thought_chunk" ->
        %{updates | thought_chunks: updates.thought_chunks ++ stream_thought_chunks(update)}

      kind == "agent_message_chunk" ->
        %{updates | message_chunks: updates.message_chunks ++ stream_message_chunks(update)}

      kind in ["tool_call", "tool_call_update"] ->
        %{updates | tool_events: updates.tool_events ++ [update]}

      true ->
        %{updates | other_updates: updates.other_updates ++ [update]}
    end
  end

  defp stream_update_kind(update) do
    if Code.ensure_loaded?(CodexStream) and function_exported?(CodexStream, :update_kind, 1) do
      CodexStream.update_kind(update)
    else
      fallback_update_kind(update)
    end
  rescue
    _ ->
      fallback_update_kind(update)
  end

  defp stream_message_chunks(update) do
    if Code.ensure_loaded?(CodexStream) and function_exported?(CodexStream, :message_chunks, 1) do
      CodexStream.message_chunks(update)
    else
      fallback_message_chunks(update)
    end
  rescue
    _ ->
      fallback_message_chunks(update)
  end

  defp stream_thought_chunks(update) do
    if Code.ensure_loaded?(CodexStream) and function_exported?(CodexStream, :thought_chunks, 1) do
      CodexStream.thought_chunks(update)
    else
      fallback_thought_chunks(update)
    end
  rescue
    _ ->
      fallback_thought_chunks(update)
  end

  defp fallback_message_chunks(update) do
    [
      get_in(update, ["content", "text"]),
      get_in(update, [:content, :text]),
      get_in(update, ["text"]),
      get_in(update, [:text])
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp fallback_thought_chunks(update) do
    [
      get_in(update, ["content", "thought"]),
      get_in(update, [:content, :thought]),
      get_in(update, ["thought"]),
      get_in(update, [:thought]),
      get_in(update, ["content", "text"]),
      get_in(update, [:content, :text]),
      get_in(update, ["text"]),
      get_in(update, [:text])
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp fallback_update_kind(update) do
    get_in(update, ["type"]) ||
      get_in(update, [:type]) ||
      get_in(update, ["sessionUpdate"]) ||
      get_in(update, [:sessionUpdate]) ||
      get_in(update, ["kind"]) ||
      get_in(update, [:kind]) ||
      "unknown"
  end

  defp normalize_prompt_response(%{"result" => result}, updates, session_id)
       when is_map(result) do
    raw_stop_reason = result["stopReason"] || result["stop_reason"] || "unknown"
    stop_reason = normalize_stop_reason(raw_stop_reason)

    {:ok,
     %{
       node: Node.self(),
       session_id: session_id,
       stop_reason: stop_reason,
       raw_stop_reason: raw_stop_reason,
       thought_chunks: updates.thought_chunks,
       message_chunks: updates.message_chunks,
       tool_events: updates.tool_events,
       other_updates: updates.other_updates,
       result: result
     }}
  end

  defp normalize_prompt_response(%{"error" => error}, _updates, _session_id) do
    {:error, {:prompt_error, error}}
  end

  defp normalize_prompt_response(other, _updates, _session_id) do
    {:error, {:invalid_prompt_response, other}}
  end

  defp normalize_stop_reason(stop_reason) do
    case stop_reason do
      value when value in ["done", "end_turn"] -> "done"
      value when value in ["cancelled", "canceled"] -> "cancelled"
      "error" -> "error"
      other -> to_string(other)
    end
  end

  defp wrap_last_prompt_result({:ok, result}), do: result
  defp wrap_last_prompt_result({:error, reason}), do: %{error: reason}

  defp connect_if_possible(%{conn_pid: pid} = state) when is_pid(pid), do: state

  defp connect_if_possible(%{agent_path: nil} = state) do
    state
    |> mark_disconnected({:invalid_acp_command, state.last_error || :missing_command})
    |> schedule_reconnect()
  end

  defp connect_if_possible(state) do
    opts = [agent_path: state.agent_path, agent_args: state.agent_args]

    handler_args = [
      bridge: self(),
      session_key: extract_session_key(state.bridge_name),
      provider: state.acp_provider,
      tool_cwd: state.tool_cwd,
      sandbox_roots: state.sandbox_roots,
      sandbox_default_root: state.sandbox_default_root,
      dangerously: state.dangerously
    ]

    start_result =
      try do
        state.acp_client_module.start_client(Hivebeam.AcpClient, handler_args, opts)
      catch
        :exit, reason -> {:error, {:start_client_exit, reason}}
      end

    case start_result do
      {:ok, conn_pid} ->
        case bootstrap_session(state, conn_pid) do
          {:ok, %{session_id: session_id, enforced_provider_mode: enforced_provider_mode}} ->
            monitor_ref = Process.monitor(conn_pid)

            Logger.info(
              "#{provider_title(state.acp_provider)} bridge connected on #{Node.self()} with session #{session_id} via #{state.agent_path} (mode=#{enforced_provider_mode})"
            )

            %{
              state
              | conn_pid: conn_pid,
                conn_monitor_ref: monitor_ref,
                session_id: session_id,
                status: :connected,
                last_error: nil,
                enforced_provider_mode: enforced_provider_mode,
                reconnect_timer_ref: cancel_retry_timer(state.reconnect_timer_ref)
            }

          {:error, reason} ->
            Process.exit(conn_pid, :kill)

            state
            |> mark_disconnected(reason)
            |> schedule_reconnect()
        end

      {:error, reason} ->
        state
        |> mark_disconnected({:start_client_failed, reason})
        |> schedule_reconnect()

      other ->
        state
        |> mark_disconnected({:unexpected_start_client_response, other})
        |> schedule_reconnect()
    end
  end

  defp bootstrap_session(state, conn_pid) do
    initialize_payload = %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{
        "fs" => %{
          "readTextFile" => true,
          "writeTextFile" => true
        },
        "terminal" => true
      },
      "clientInfo" => %{
        "name" => "hivebeam",
        "version" => "0.1.0"
      }
    }

    session_new_payload = session_new_payload(state)

    with %{"result" => _init_result} <-
           request(state, conn_pid, "initialize", initialize_payload, state.connect_timeout_ms),
         %{"result" => session_result} when is_map(session_result) <-
           request(
             state,
             conn_pid,
             "session/new",
             session_new_payload,
             state.connect_timeout_ms
           ),
         session_id when is_binary(session_id) and session_id != "" <-
           session_result["sessionId"] || session_result["session_id"],
         {:ok, enforced_provider_mode} <-
           enforce_provider_mode(state, conn_pid, session_id, session_result) do
      {:ok, %{session_id: session_id, enforced_provider_mode: enforced_provider_mode}}
    else
      %{"error" => error} -> {:error, {:bootstrap_error, error}}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :missing_session_id}
      other -> {:error, {:unexpected_bootstrap_response, other}}
    end
  end

  defp request(state, conn_pid, method, payload, timeout_ms) do
    state.connection_module.send_request(conn_pid, method, payload, timeout_ms)
  catch
    :exit, reason ->
      %{"error" => %{code: -32000, message: "request exited", reason: inspect(reason)}}
  end

  defp mark_disconnected(state, reason) do
    %{
      state
      | conn_pid: nil,
        conn_monitor_ref: nil,
        session_id: nil,
        status: :degraded,
        last_error: reason,
        enforced_provider_mode: nil
    }
  end

  defp session_new_payload(state) do
    payload = %{"cwd" => state.tool_cwd, "mcpServers" => []}

    case state.acp_provider do
      "claude" ->
        Map.put(payload, "_meta", %{
          "claudeCode" => %{
            "options" => %{
              "settingSources" => ["project"]
            }
          }
        })

      _ ->
        payload
    end
  end

  defp provider_mode_for_approval("codex", :allow), do: "full-access"
  defp provider_mode_for_approval("codex", _), do: "read-only"

  defp provider_mode_for_approval("claude", :allow), do: "bypassPermissions"
  defp provider_mode_for_approval("claude", :deny), do: "dontAsk"
  defp provider_mode_for_approval("claude", :ask), do: "default"

  defp provider_mode_for_approval(_provider, :allow), do: "full-access"
  defp provider_mode_for_approval(_provider, _approval_mode), do: "read-only"

  defp enforce_provider_mode(state, conn_pid, session_id, session_result) do
    desired_mode = provider_mode_for_approval(state.acp_provider, state.default_approval_mode)

    with :ok <- ensure_mode_available(desired_mode, available_mode_ids(session_result)),
         %{"result" => _mode_result} <-
           request(
             state,
             conn_pid,
             "session/set_mode",
             %{"sessionId" => session_id, "modeId" => desired_mode},
             state.connect_timeout_ms
           ) do
      {:ok, desired_mode}
    else
      {:error, reason} ->
        {:error, reason}

      %{"error" => error} ->
        {:error, {:mode_enforcement_failed, error}}

      other ->
        {:error, {:mode_enforcement_failed, {:unexpected_response, other}}}
    end
  end

  defp available_mode_ids(session_result) when is_map(session_result) do
    session_result
    |> get_in(["modes", "availableModes"])
    |> List.wrap()
    |> Enum.reduce([], fn mode, acc ->
      case mode_id(mode) do
        nil -> acc
        id -> [id | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp ensure_mode_available(mode_id, available_mode_ids)
       when is_binary(mode_id) and is_list(available_mode_ids) do
    if mode_id in available_mode_ids do
      :ok
    else
      {:error, {:mode_unavailable, mode_id, available_mode_ids}}
    end
  end

  defp mode_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp mode_id(%{id: id}) when is_binary(id) and id != "", do: id
  defp mode_id(_), do: nil

  defp maybe_reply_prompt_error(state, reason) do
    case state.in_flight_prompt do
      nil ->
        state

      in_flight ->
        notify_stream_targets(in_flight.stream_targets, %{
          event: :error,
          node: Node.self(),
          bridge_name: state.bridge_name,
          session_id: state.session_id,
          reason: reason
        })

        GenServer.reply(in_flight.from, {:error, reason})
        %{state | in_flight_prompt: nil, prompt_updates: empty_updates()}
    end
  end

  defp schedule_reconnect(%{reconnect_timer_ref: ref} = state) when is_reference(ref), do: state

  defp schedule_reconnect(state) do
    ref = Process.send_after(self(), :retry_connect, state.reconnect_ms)
    %{state | reconnect_timer_ref: ref}
  end

  defp cancel_retry_timer(nil), do: nil

  defp cancel_retry_timer(ref) do
    Process.cancel_timer(ref)
    nil
  end

  defp extract_session_key({:via, Registry, {_registry, {:session_bridge, session_key}}})
       when is_binary(session_key),
       do: session_key

  defp extract_session_key(_bridge_name), do: nil

  defp resolve_command({:ok, {path, args}}) when is_binary(path) and is_list(args),
    do: {:ok, {path, args}}

  defp resolve_command({path, args}) when is_binary(path) and is_list(args),
    do: {:ok, {path, args}}

  defp resolve_command({:error, _reason} = error), do: error

  defp resolve_command(command) when is_binary(command),
    do: CodexConfig.parse_acp_command(command)

  defp resolve_command(_), do: {:error, :invalid_acp_command}

  defp extract_stream_targets(opts) do
    opts
    |> Keyword.get(:stream_to, [])
    |> List.wrap()
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  defp normalize_approval_target(opts) do
    case Keyword.get(opts, :approval_to) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp normalize_approval_mode(mode, fallback)

  defp normalize_approval_mode(nil, fallback), do: fallback
  defp normalize_approval_mode(:ask, _fallback), do: :ask
  defp normalize_approval_mode(:allow, _fallback), do: :allow
  defp normalize_approval_mode(:deny, _fallback), do: :deny
  defp normalize_approval_mode("ask", _fallback), do: :ask
  defp normalize_approval_mode("allow", _fallback), do: :allow
  defp normalize_approval_mode("deny", _fallback), do: :deny
  defp normalize_approval_mode(_, fallback), do: fallback

  defp current_approval_mode(%{in_flight_prompt: %{approval_mode: mode}}), do: mode
  defp current_approval_mode(state), do: state.default_approval_mode

  defp current_approval_target(%{in_flight_prompt: %{approval_to: pid}}) when is_pid(pid), do: pid

  defp current_approval_target(%{in_flight_prompt: %{stream_targets: [pid | _]}})
       when is_pid(pid),
       do: pid

  defp current_approval_target(_state), do: nil

  defp approve_tool_request(state, request) do
    case current_approval_mode(state) do
      :allow ->
        {:ok, true}

      :deny ->
        {:ok, false}

      :ask ->
        case current_approval_target(state) do
          pid when is_pid(pid) -> dispatch_approval_request(pid, state, request)
          _ -> {:error, :approval_target_unavailable}
        end
    end
  end

  defp dispatch_approval_request(target_pid, state, request) do
    ref = make_ref()

    send(target_pid, {
      :codex_tool_approval_request,
      %{
        ref: ref,
        reply_to: self(),
        node: Node.self(),
        bridge_name: state.bridge_name,
        session_id: state.session_id,
        request: request
      }
    })

    receive do
      {:codex_tool_approval_reply, ^ref, decision} when is_boolean(decision) ->
        {:ok, decision}
    after
      state.approval_timeout_ms ->
        {:error, :approval_timeout}
    end
  end

  defp notify_prompt_stream(%{in_flight_prompt: %{stream_targets: stream_targets}}, payload) do
    notify_stream_targets(stream_targets, payload)
  end

  defp notify_prompt_stream(_state, _payload), do: :ok

  defp notify_stream_targets(stream_targets, payload) do
    Enum.each(stream_targets, fn pid ->
      send(pid, {:codex_prompt_stream, payload})
    end)
  end

  defp empty_updates do
    %{
      thought_chunks: [],
      message_chunks: [],
      tool_events: [],
      other_updates: []
    }
  end

  defp normalize_timeout_ms(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_timeout_ms(_value, default), do: default

  defp normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> @default_provider
      value -> value
    end
  end

  defp normalize_provider(provider) when is_atom(provider) do
    provider |> Atom.to_string() |> normalize_provider()
  end

  defp normalize_provider(_provider), do: @default_provider

  defp normalize_dangerously(value) when is_boolean(value), do: value

  defp normalize_dangerously(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      _ -> false
    end
  end

  defp normalize_dangerously(_value), do: false

  defp provider_title("claude"), do: "Claude"
  defp provider_title("codex"), do: "Codex"
  defp provider_title(other), do: String.capitalize(other)
end
