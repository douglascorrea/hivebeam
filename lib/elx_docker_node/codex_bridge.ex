defmodule ElxDockerNode.CodexBridge do
  @moduledoc false
  use GenServer

  require Logger

  alias ElxDockerNode.CodexConfig

  @type status :: :connecting | :connected | :degraded
  @type approval_mode :: :ask | :allow | :deny

  @default_approval_timeout_ms 120_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, CodexConfig.bridge_name())
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec prompt(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(prompt, opts \\ []) when is_binary(prompt) do
    bridge_name = Keyword.get(opts, :bridge_name, CodexConfig.bridge_name())
    timeout_ms = Keyword.get(opts, :timeout, CodexConfig.prompt_timeout_ms()) + 5_000
    GenServer.call(bridge_name, {:prompt, prompt, opts}, timeout_ms)
  end

  @spec request_tool_approval(map(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def request_tool_approval(request, opts \\ []) when is_map(request) do
    bridge_name = Keyword.get(opts, :bridge_name, CodexConfig.bridge_name())
    timeout_ms = Keyword.get(opts, :timeout, CodexConfig.prompt_timeout_ms())
    GenServer.call(bridge_name, {:tool_approval, request}, timeout_ms)
  end

  @spec status() :: {:ok, map()}
  def status do
    status(CodexConfig.bridge_name())
  end

  @spec status(GenServer.server()) :: {:ok, map()}
  def status(server) do
    GenServer.call(server, :status)
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, %{})
    acpex_module = Keyword.get(opts, :acpex_module, ACPex)
    connection_module = Keyword.get(opts, :connection_module, ACPex.Protocol.Connection)

    bridge_name =
      Keyword.get(opts, :name, Map.get(config, :bridge_name, CodexConfig.bridge_name()))

    {agent_path, agent_args, command_error} =
      case resolve_command(Map.get(config, :acp_command, CodexConfig.acp_command())) do
        {:ok, {path, args}} -> {path, args, nil}
        {:error, reason} -> {nil, [], reason}
      end

    default_approval_mode =
      config
      |> Map.get(:approval_mode, :ask)
      |> normalize_approval_mode(:ask)

    state = %{
      acpex_module: acpex_module,
      connection_module: connection_module,
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
      reconnect_ms: Map.get(config, :reconnect_ms, CodexConfig.cluster_retry_ms()),
      reconnect_timer_ref: nil,
      tool_cwd: Map.get(config, :tool_cwd, File.cwd!()),
      default_approval_mode: default_approval_mode,
      approval_timeout_ms: Map.get(config, :approval_timeout_ms, @default_approval_timeout_ms)
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
      status: state.status,
      connected: state.status == :connected,
      session_id: state.session_id,
      connection_pid: state.conn_pid,
      in_flight_prompt: not is_nil(state.in_flight_prompt),
      last_error: state.last_error,
      last_prompt_result: state.last_prompt_result,
      approval_mode: current_approval_mode(state)
    }

    {:reply, {:ok, response}, state}
  end

  def handle_call({:tool_approval, request}, _from, state) when is_map(request) do
    {:reply, approve_tool_request(state, request), state}
  end

  def handle_call({:prompt, prompt, opts}, from, state) when is_binary(prompt) do
    cond do
      state.status != :connected or is_nil(state.conn_pid) or is_nil(state.session_id) ->
        {:reply, {:error, {:bridge_not_connected, state.last_error}}, state}

      state.in_flight_prompt != nil ->
        {:reply, {:error, :prompt_in_progress}, state}

      true ->
        timeout_ms = Keyword.get(opts, :timeout, state.prompt_timeout_ms)
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
      session_id: state.session_id,
      reason: {:prompt_task_down, reason}
    })

    GenServer.reply(in_flight.from, {:error, {:prompt_task_down, reason}})
    {:noreply, %{state | in_flight_prompt: nil, prompt_updates: empty_updates()}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_monitor_ref: ref} = state) do
    Logger.warning("Codex ACP connection dropped: #{inspect(reason)}")

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
    kind = update_kind(update)

    cond do
      kind == "agent_thought_chunk" ->
        %{updates | thought_chunks: updates.thought_chunks ++ extract_thought_chunks(update)}

      kind == "agent_message_chunk" ->
        %{updates | message_chunks: updates.message_chunks ++ extract_message_chunks(update)}

      kind in ["tool_call", "tool_call_update"] ->
        %{updates | tool_events: updates.tool_events ++ [update]}

      true ->
        %{updates | other_updates: updates.other_updates ++ [update]}
    end
  end

  defp extract_thought_chunks(update) do
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
    |> case do
      [] ->
        get_in(update, ["content", "content"])
        |> normalize_content_texts()

      direct ->
        direct
    end
  end

  defp extract_message_chunks(update) do
    [
      get_in(update, ["content", "text"]),
      get_in(update, [:content, :text]),
      get_in(update, ["text"]),
      get_in(update, [:text])
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> case do
      [] ->
        get_in(update, ["content", "content"])
        |> normalize_content_texts()

      direct ->
        direct
    end
  end

  defp normalize_content_texts(list) when is_list(list) do
    list
    |> Enum.map(fn item ->
      get_in(item, ["text"]) || get_in(item, [:text])
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp normalize_content_texts(_), do: []

  defp update_kind(update) do
    get_in(update, ["type"]) ||
      get_in(update, [:type]) ||
      get_in(update, ["kind"]) ||
      get_in(update, [:kind]) ||
      get_in(update, ["sessionUpdate"]) ||
      get_in(update, [:sessionUpdate]) ||
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
    handler_args = [bridge: self(), tool_cwd: state.tool_cwd]

    case state.acpex_module.start_client(ElxDockerNode.CodexAcpClient, handler_args, opts) do
      {:ok, conn_pid} ->
        case bootstrap_session(state, conn_pid) do
          {:ok, session_id} ->
            monitor_ref = Process.monitor(conn_pid)

            Logger.info(
              "Codex bridge connected on #{Node.self()} with session #{session_id} via #{state.agent_path}"
            )

            %{
              state
              | conn_pid: conn_pid,
                conn_monitor_ref: monitor_ref,
                session_id: session_id,
                status: :connected,
                last_error: nil,
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
        "name" => "elx-docker-node",
        "version" => "0.1.0"
      }
    }

    with %{"result" => _init_result} <-
           request(state, conn_pid, "initialize", initialize_payload, state.connect_timeout_ms),
         %{"result" => session_result} when is_map(session_result) <-
           request(
             state,
             conn_pid,
             "session/new",
             %{"cwd" => File.cwd!(), "mcpServers" => []},
             state.connect_timeout_ms
           ),
         session_id when is_binary(session_id) and session_id != "" <-
           session_result["sessionId"] || session_result["session_id"] do
      {:ok, session_id}
    else
      %{"error" => error} -> {:error, {:bootstrap_error, error}}
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
        last_error: reason
    }
  end

  defp maybe_reply_prompt_error(state, reason) do
    case state.in_flight_prompt do
      nil ->
        state

      in_flight ->
        notify_stream_targets(in_flight.stream_targets, %{
          event: :error,
          node: Node.self(),
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
end
