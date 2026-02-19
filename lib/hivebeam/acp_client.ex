defmodule Hivebeam.AcpClient do
  @moduledoc false
  @behaviour Hivebeam.Acp.ClientHandler

  require Logger

  alias Hivebeam.CodexBridge
  alias Hivebeam.Gateway.Config

  @default_approval_timeout_ms 120_000
  @default_terminal_output_limit 200_000
  @terminal_wait_timeout_ms 300_000

  @impl true
  def init(args) do
    tool_cwd =
      args
      |> Keyword.get(:tool_cwd, File.cwd!())
      |> resolve_path(File.cwd!())

    sandbox_roots =
      args
      |> Keyword.get(:sandbox_roots, [tool_cwd])
      |> normalize_sandbox_roots(tool_cwd)

    sandbox_default_root =
      args
      |> Keyword.get(:sandbox_default_root, tool_cwd)
      |> normalize_sandbox_default_root(tool_cwd, sandbox_roots)

    {:ok,
     %{
       bridge: Keyword.fetch!(args, :bridge),
       tool_cwd: tool_cwd,
       sandbox_roots: sandbox_roots,
       sandbox_default_root: sandbox_default_root,
       dangerously:
         args
         |> Keyword.get(:dangerously, Config.sandbox_dangerously_enabled?())
         |> normalize_dangerously(),
       approval_timeout_ms: Keyword.get(args, :approval_timeout_ms, @default_approval_timeout_ms),
       approval_fun: Keyword.get(args, :approval_fun, &default_approval/2),
       terminals: %{},
       terminal_monitors: %{}
     }}
  end

  @impl true
  def handle_notification("session/update", params, state) when is_map(params) do
    notification = %{
      session_id: fetch(params, :session_id) || fetch(params, :sessionId),
      update: fetch(params, :update)
    }

    send(state.bridge, {:acp_session_update, notification})
    {:noreply, state}
  end

  def handle_notification(_method, _params, state), do: {:noreply, state}

  @impl true
  def handle_request("session/request_permission", request, state) when is_map(request) do
    state = drain_terminal_messages(state)
    options = permission_options(request)

    details = %{
      session_id: fetch(request, :session_id) || fetch(request, :sessionId),
      tool_call: fetch(request, :tool_call) || fetch(request, :toolCall),
      options: options
    }

    outcome =
      case approval_decision(state, "session/request_permission", details) do
        :allow ->
          case choose_option_id(options, :allow) do
            nil -> cancelled_permission_outcome()
            option_id -> selected_permission_outcome(option_id)
          end

        :deny ->
          case choose_option_id(options, :deny) do
            nil -> cancelled_permission_outcome()
            option_id -> selected_permission_outcome(option_id)
          end

        :cancelled ->
          cancelled_permission_outcome()
      end

    {:ok, %{"outcome" => outcome}, state}
  end

  def handle_request("fs/read_text_file", request, state) when is_map(request) do
    state = drain_terminal_messages(state)
    path = resolve_path(fetch(request, :path), state.tool_cwd)
    line = fetch(request, :line)
    limit = fetch(request, :limit)

    with :ok <- ensure_sandbox_path(state, "fs/read_text_file", path),
         :ok <- ensure_approved(state, "fs/read_text_file", %{path: path}),
         {:ok, content} <- File.read(path) do
      content = apply_line_limit(content, line, limit)
      {:ok, %{"content" => content}, state}
    else
      {:error, reason} when is_map(reason) -> {:error, reason, state}
      {:error, reason} -> {:error, io_error("fs/read_text_file failed", reason), state}
    end
  end

  def handle_request("fs/write_text_file", request, state) when is_map(request) do
    state = drain_terminal_messages(state)
    path = resolve_path(fetch(request, :path), state.tool_cwd)
    content = fetch(request, :content) || ""

    with :ok <- ensure_sandbox_path(state, "fs/write_text_file", path),
         :ok <- ensure_approved(state, "fs/write_text_file", %{path: path}),
         :ok <- ensure_parent_dir(path),
         :ok <- File.write(path, content) do
      {:ok, %{}, state}
    else
      {:error, reason} when is_map(reason) -> {:error, reason, state}
      {:error, reason} -> {:error, io_error("fs/write_text_file failed", reason), state}
    end
  end

  def handle_request("terminal/create", request, state) when is_map(request) do
    state = drain_terminal_messages(state)

    cwd =
      case fetch(request, :cwd) do
        value when is_binary(value) and value != "" -> resolve_path(value, state.tool_cwd)
        _ -> state.tool_cwd
      end

    command = fetch(request, :command)
    args = fetch(request, :args) |> List.wrap()

    with true <- is_binary(command) and command != "",
         :ok <- ensure_sandbox_path(state, "terminal/create", cwd),
         :ok <-
           ensure_approved(state, "terminal/create", %{command: command, args: args, cwd: cwd}) do
      terminal_id = "term-" <> Integer.to_string(System.unique_integer([:positive]))
      env_pairs = normalize_env(fetch(request, :env))

      output_limit =
        fetch(request, :output_byte_limit) || fetch(request, :outputByteLimit) ||
          @default_terminal_output_limit

      owner = self()

      {worker_pid, monitor_ref} =
        spawn_monitor(fn ->
          result = run_terminal_command(command, args, cwd, env_pairs, output_limit)
          send(owner, {:terminal_finished, terminal_id, result})
        end)

      terminal = %{
        worker_pid: worker_pid,
        monitor_ref: monitor_ref,
        done?: false,
        output: "",
        truncated: false,
        exit_code: nil,
        signal: nil
      }

      new_state =
        state
        |> put_terminal(terminal_id, terminal)
        |> put_terminal_monitor(monitor_ref, terminal_id)

      {:ok, %{"terminalId" => terminal_id}, new_state}
    else
      false -> {:error, %{code: -32_001, message: "terminal/create requires command"}, state}
      {:error, reason} when is_map(reason) -> {:error, reason, state}
      {:error, reason} -> {:error, io_error("terminal/create failed", reason), state}
    end
  end

  def handle_request("terminal/output", request, state) when is_map(request) do
    state = drain_terminal_messages(state)

    with {:ok, terminal} <-
           fetch_terminal(state, fetch(request, :terminal_id) || fetch(request, :terminalId)) do
      response = %{
        "output" => terminal.output,
        "truncated" => terminal.truncated,
        "exitStatus" => terminal_exit_status(terminal)
      }

      {:ok, response, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_request("terminal/wait_for_exit", request, state) when is_map(request) do
    state = drain_terminal_messages(state)
    terminal_id = fetch(request, :terminal_id) || fetch(request, :terminalId)

    with {:ok, _terminal} <- fetch_terminal(state, terminal_id),
         {:ok, terminal, new_state} <-
           wait_for_terminal_exit(state, terminal_id, @terminal_wait_timeout_ms) do
      response = %{"exitCode" => terminal.exit_code, "signal" => terminal.signal}
      {:ok, response, new_state}
    else
      {:error, reason, new_state} -> {:error, reason, new_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_request("terminal/kill", request, state) when is_map(request) do
    state = drain_terminal_messages(state)
    terminal_id = fetch(request, :terminal_id) || fetch(request, :terminalId)

    with {:ok, terminal} <- fetch_terminal(state, terminal_id),
         :ok <- ensure_approved(state, "terminal/kill", %{terminal_id: terminal_id}) do
      if not terminal.done? and is_pid(terminal.worker_pid) and
           Process.alive?(terminal.worker_pid) do
        Process.exit(terminal.worker_pid, :kill)
      end

      new_state =
        complete_terminal(state, terminal_id, %{
          output: terminal.output,
          truncated: terminal.truncated,
          exit_code: terminal.exit_code,
          signal: terminal.signal || "SIGKILL"
        })

      {:ok, %{}, new_state}
    else
      {:error, reason} when is_map(reason) -> {:error, reason, state}
      {:error, reason} -> {:error, io_error("terminal/kill failed", reason), state}
    end
  end

  def handle_request("terminal/release", request, state) when is_map(request) do
    state = drain_terminal_messages(state)
    terminal_id = fetch(request, :terminal_id) || fetch(request, :terminalId)

    with {:ok, terminal} <- fetch_terminal(state, terminal_id) do
      if not terminal.done? and is_pid(terminal.worker_pid) and
           Process.alive?(terminal.worker_pid) do
        Process.exit(terminal.worker_pid, :kill)
      end

      new_state = delete_terminal(state, terminal_id, terminal.monitor_ref)
      {:ok, %{}, new_state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_request(_method, _params, state) do
    {:error, %{code: -32_601, message: "method not found"}, state}
  end

  @impl true
  def handle_info({:terminal_finished, _terminal_id, _result} = message, state) do
    {:noreply, handle_terminal_message(message, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason} = message, state)
      when is_map_key(state.terminal_monitors, ref) do
    {:noreply, handle_terminal_message(message, state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp default_approval(request, state) do
    CodexBridge.request_tool_approval(request,
      bridge_name: state.bridge,
      timeout: state.approval_timeout_ms
    )
  end

  defp ensure_sandbox_path(state, operation, path) do
    case Config.ensure_path_allowed(path, state.sandbox_roots, dangerously: state.dangerously) do
      :ok ->
        :ok

      {:error, {:sandbox_violation, details}} ->
        {:error, sandbox_error(operation, details)}

      {:error, reason} ->
        {:error, sandbox_error(operation, %{path: path, reason: inspect(reason)})}
    end
  end

  defp ensure_approved(state, operation, details) do
    case approval_decision(state, operation, details) do
      :allow ->
        :ok

      :deny ->
        {:error, %{code: -32_003, message: "#{operation} denied by approval policy"}}

      :cancelled ->
        {:error, %{code: -32_003, message: "#{operation} approval cancelled"}}
    end
  end

  defp approval_decision(state, operation, details) do
    request = %{operation: operation, details: details}

    case state.approval_fun.(request, state) do
      {:ok, true} ->
        :allow

      {:ok, false} ->
        :deny

      {:error, reason} ->
        Logger.warning("#{operation} approval failed: #{inspect(reason)}")
        :cancelled

      true ->
        :allow

      false ->
        :deny

      other ->
        Logger.warning(
          "#{operation} approval handler returned unexpected result: #{inspect(other)}"
        )

        :cancelled
    end
  end

  defp permission_options(request) do
    request
    |> fetch(:options)
    |> List.wrap()
    |> Enum.reduce([], fn option, acc ->
      option_id = fetch(option, :option_id) || fetch(option, :optionId)

      if is_binary(option_id) and option_id != "" do
        option_name = fetch(option, :name)

        normalized = %{
          "optionId" => option_id,
          "name" =>
            if(is_binary(option_name) and option_name != "", do: option_name, else: option_id),
          "kind" => normalize_option_kind(fetch(option, :kind))
        }

        [normalized | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_option_kind(kind) when is_binary(kind), do: kind
  defp normalize_option_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_option_kind(_), do: nil

  defp choose_option_id(options, :allow) do
    preferred_option_id(options, [
      &allow_once_kind?/1,
      &allow_once_label?/1,
      &allow_kind?/1,
      &allow_label?/1
    ]) || first_non_reject_option_id(options) || first_option_id(options)
  end

  defp choose_option_id(options, :deny) do
    preferred_option_id(options, [
      &reject_once_kind?/1,
      &reject_label?/1,
      &reject_kind?/1
    ])
  end

  defp preferred_option_id(options, predicates) when is_list(predicates) do
    Enum.find_value(predicates, fn predicate ->
      options
      |> Enum.find(predicate)
      |> option_id()
    end)
  end

  defp first_non_reject_option_id(options) do
    options
    |> Enum.reject(&reject_label?/1)
    |> first_option_id()
  end

  defp first_option_id([%{"optionId" => option_id} | _]) when is_binary(option_id), do: option_id
  defp first_option_id(_), do: nil

  defp option_id(%{"optionId" => option_id}) when is_binary(option_id), do: option_id
  defp option_id(_), do: nil

  defp allow_once_kind?(option), do: option_kind(option) in ["allow_once", "approved"]
  defp allow_kind?(option), do: option_kind(option) in ["allow_always", "approved-for-session"]
  defp reject_once_kind?(option), do: option_kind(option) in ["reject_once", "abort"]
  defp reject_kind?(option), do: option_kind(option) in ["reject_always", "cancelled"]

  defp allow_once_label?(option) do
    label = option_label(option)
    allow_label_text?(label) and not persistent_label_text?(label)
  end

  defp allow_label?(option) do
    option
    |> option_label()
    |> allow_label_text?()
  end

  defp reject_label?(option) do
    option
    |> option_label()
    |> reject_label_text?()
  end

  defp option_kind(option) do
    option
    |> fetch(:kind)
    |> normalize_label()
  end

  defp option_label(option) do
    [fetch(option, :name), Map.get(option, "optionId"), fetch(option, :option_id)]
    |> Enum.find(&(is_binary(&1) and &1 != ""))
    |> normalize_label()
  end

  defp normalize_label(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
  end

  defp normalize_label(_), do: ""

  defp allow_label_text?(label) when is_binary(label) do
    label =~ "allow" or label =~ "approve" or label =~ "approved" or label == "yes"
  end

  defp reject_label_text?(label) when is_binary(label) do
    label =~ "reject" or label =~ "deny" or label =~ "abort" or label =~ "cancel" or
      String.starts_with?(label, "no")
  end

  defp persistent_label_text?(label) when is_binary(label) do
    label =~ "always" or label =~ "session"
  end

  defp selected_permission_outcome(option_id) do
    %{
      "outcome" => "selected",
      "optionId" => option_id
    }
  end

  defp cancelled_permission_outcome do
    %{"outcome" => "cancelled"}
  end

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp resolve_path(path, cwd) when is_binary(path), do: Path.expand(path, cwd)
  defp resolve_path(_path, cwd), do: cwd

  defp apply_line_limit(content, nil, nil), do: content

  defp apply_line_limit(content, line, limit) do
    start_index =
      case line do
        value when is_integer(value) and value > 0 -> value - 1
        _ -> 0
      end

    content
    |> String.split("\n", trim: false)
    |> Enum.drop(start_index)
    |> maybe_take(limit)
    |> Enum.join("\n")
  end

  defp maybe_take(lines, value) when is_integer(value) and value > 0, do: Enum.take(lines, value)
  defp maybe_take(lines, _), do: lines

  defp normalize_env(nil), do: []

  defp normalize_env(env) when is_list(env) do
    env
    |> Enum.reduce([], fn item, acc ->
      name = fetch(item, :name)
      value = fetch(item, :value)

      if is_binary(name) do
        [{name, to_string(value || "")} | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_env(_), do: []

  defp run_terminal_command(command, args, cwd, env_pairs, output_limit) do
    options =
      [stderr_to_stdout: true, cd: cwd]
      |> maybe_put_env(env_pairs)

    try do
      {output, exit_code} = System.cmd(command, args, options)
      {output, truncated} = truncate_output(output, output_limit)

      %{
        output: output,
        truncated: truncated,
        exit_code: exit_code,
        signal: nil
      }
    rescue
      error ->
        {output, truncated} = truncate_output(Exception.message(error), output_limit)

        %{
          output: output,
          truncated: truncated,
          exit_code: 127,
          signal: nil
        }
    catch
      kind, reason ->
        {output, truncated} =
          truncate_output("terminal execution #{kind}: #{inspect(reason)}", output_limit)

        %{
          output: output,
          truncated: truncated,
          exit_code: 1,
          signal: nil
        }
    end
  end

  defp maybe_put_env(options, []), do: options
  defp maybe_put_env(options, env_pairs), do: Keyword.put(options, :env, env_pairs)

  defp truncate_output(output, limit) when is_integer(limit) and limit > 0 do
    if byte_size(output) > limit do
      {binary_part(output, 0, limit), true}
    else
      {output, false}
    end
  end

  defp truncate_output(output, _), do: {output, false}

  defp terminal_exit_status(%{done?: true} = terminal) do
    %{
      "exitCode" => terminal.exit_code,
      "signal" => terminal.signal
    }
  end

  defp terminal_exit_status(_terminal), do: nil

  defp wait_for_terminal_exit(state, terminal_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_terminal_exit(state, terminal_id, deadline)
  end

  defp do_wait_for_terminal_exit(state, terminal_id, deadline) do
    state = drain_terminal_messages(state)

    case fetch_terminal(state, terminal_id) do
      {:ok, %{done?: true} = terminal} ->
        {:ok, terminal, state}

      {:ok, _terminal} ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error,
           %{code: -32_002, message: "terminal/wait_for_exit timed out for #{terminal_id}"},
           state}
        else
          wait_for_more_terminal_events(state, terminal_id, deadline)
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp wait_for_more_terminal_events(state, terminal_id, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:terminal_finished, _terminal_id, _result} = message ->
        state
        |> then(&handle_terminal_message(message, &1))
        |> do_wait_for_terminal_exit(terminal_id, deadline)

      {:DOWN, ref, :process, _pid, _reason} = message
      when is_map_key(state.terminal_monitors, ref) ->
        state
        |> then(&handle_terminal_message(message, &1))
        |> do_wait_for_terminal_exit(terminal_id, deadline)
    after
      min(timeout, 200) ->
        do_wait_for_terminal_exit(state, terminal_id, deadline)
    end
  end

  defp drain_terminal_messages(state) do
    receive do
      {:terminal_finished, _terminal_id, _result} = message ->
        state
        |> then(&handle_terminal_message(message, &1))
        |> drain_terminal_messages()

      {:DOWN, ref, :process, _pid, _reason} = message
      when is_map_key(state.terminal_monitors, ref) ->
        state
        |> then(&handle_terminal_message(message, &1))
        |> drain_terminal_messages()
    after
      0 ->
        state
    end
  end

  defp handle_terminal_message({:terminal_finished, terminal_id, result}, state) do
    complete_terminal(state, terminal_id, result)
  end

  defp handle_terminal_message({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.terminal_monitors, ref) do
      {nil, _} ->
        state

      {terminal_id, monitor_map} ->
        case Map.fetch(state.terminals, terminal_id) do
          :error ->
            %{state | terminal_monitors: monitor_map}

          {:ok, terminal} ->
            base_state = %{state | terminal_monitors: monitor_map}

            if terminal.done? do
              base_state
            else
              complete_terminal(base_state, terminal_id, %{
                output: terminal.output,
                truncated: terminal.truncated,
                exit_code: terminal.exit_code || 1,
                signal: normalize_signal(reason)
              })
            end
        end
    end
  end

  defp handle_terminal_message(_message, state), do: state

  defp normalize_signal(:normal), do: nil
  defp normalize_signal(:killed), do: "SIGKILL"
  defp normalize_signal(reason), do: to_string(reason)

  defp fetch_terminal(state, terminal_id) do
    case Map.fetch(state.terminals, terminal_id) do
      {:ok, terminal} -> {:ok, terminal}
      :error -> {:error, %{code: -32_001, message: "terminal not found: #{terminal_id}"}}
    end
  end

  defp put_terminal(state, terminal_id, terminal) do
    %{state | terminals: Map.put(state.terminals, terminal_id, terminal)}
  end

  defp put_terminal_monitor(state, monitor_ref, terminal_id) do
    %{state | terminal_monitors: Map.put(state.terminal_monitors, monitor_ref, terminal_id)}
  end

  defp delete_terminal(state, terminal_id, monitor_ref) do
    %{
      state
      | terminals: Map.delete(state.terminals, terminal_id),
        terminal_monitors: Map.delete(state.terminal_monitors, monitor_ref)
    }
  end

  defp complete_terminal(state, terminal_id, result) do
    case Map.fetch(state.terminals, terminal_id) do
      :error ->
        state

      {:ok, terminal} ->
        monitor_ref = terminal.monitor_ref

        updated_terminal =
          terminal
          |> Map.put(:done?, true)
          |> Map.put(:output, result[:output] || "")
          |> Map.put(:truncated, result[:truncated] || false)
          |> Map.put(:exit_code, result[:exit_code])
          |> Map.put(:signal, result[:signal])

        %{
          state
          | terminals: Map.put(state.terminals, terminal_id, updated_terminal),
            terminal_monitors: Map.delete(state.terminal_monitors, monitor_ref)
        }
    end
  end

  defp io_error(message, reason) do
    %{code: -32_001, message: "#{message}: #{inspect(reason)}"}
  end

  defp sandbox_error(operation, details) do
    %{
      code: -32_004,
      message: "#{operation} blocked by sandbox policy",
      details: details
    }
  end

  defp normalize_sandbox_roots(roots, tool_cwd) do
    roots
    |> List.wrap()
    |> Enum.reduce([], fn root, acc ->
      if is_binary(root) and root != "" do
        case Config.canonicalize_path(root) do
          {:ok, canonical_root} -> [canonical_root | acc]
          _ -> acc
        end
      else
        acc
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
    |> case do
      [] -> [tool_cwd]
      values -> values
    end
  end

  defp normalize_sandbox_default_root(default_root, tool_cwd, sandbox_roots) do
    candidate =
      if is_binary(default_root) and default_root != "" do
        default_root
      else
        tool_cwd
      end

    case Config.canonicalize_path(candidate) do
      {:ok, canonical_root} -> canonical_root
      _ -> List.first(sandbox_roots) || tool_cwd
    end
  end

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

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch(_map, _key), do: nil
end
