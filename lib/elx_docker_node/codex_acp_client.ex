defmodule ElxDockerNode.CodexAcpClient do
  @moduledoc false
  @behaviour ACPex.Client

  alias ACPex.Schema.Client.{FsReadTextFileRequest, FsReadTextFileResponse}
  alias ACPex.Schema.Client.{FsWriteTextFileRequest, FsWriteTextFileResponse}
  alias ACPex.Schema.Client.Terminal.{CreateRequest, CreateResponse}
  alias ACPex.Schema.Client.Terminal.{KillRequest, KillResponse}
  alias ACPex.Schema.Client.Terminal.{OutputRequest, OutputResponse}
  alias ACPex.Schema.Client.Terminal.{ReleaseRequest, ReleaseResponse}
  alias ACPex.Schema.Client.Terminal.{WaitForExitRequest, WaitForExitResponse}
  alias ACPex.Schema.Session.UpdateNotification
  alias ElxDockerNode.CodexBridge

  @default_approval_timeout_ms 120_000
  @default_terminal_output_limit 200_000
  @terminal_wait_timeout_ms 300_000

  @impl true
  def init(args) do
    {:ok,
     %{
       bridge: Keyword.fetch!(args, :bridge),
       tool_cwd: Keyword.get(args, :tool_cwd, File.cwd!()),
       approval_timeout_ms: Keyword.get(args, :approval_timeout_ms, @default_approval_timeout_ms),
       approval_fun: Keyword.get(args, :approval_fun, &default_approval/2),
       terminals: %{},
       terminal_monitors: %{}
     }}
  end

  @impl true
  def handle_session_update(%UpdateNotification{} = notification, state) do
    send(state.bridge, {:acp_session_update, notification})
    {:noreply, state}
  end

  @impl true
  def handle_fs_read_text_file(%FsReadTextFileRequest{} = request, state) do
    state = drain_terminal_messages(state)
    path = resolve_path(request.path, state.tool_cwd)

    with :ok <- ensure_approved(state, "fs/read_text_file", %{path: path}),
         {:ok, content} <- File.read(path) do
      content = apply_line_limit(content, request.line, request.limit)
      {:ok, %FsReadTextFileResponse{content: content}, state}
    else
      {:error, reason} when is_map(reason) -> {:error, reason, state}
      {:error, reason} -> {:error, io_error("fs/read_text_file failed", reason), state}
    end
  end

  @impl true
  def handle_fs_write_text_file(%FsWriteTextFileRequest{} = request, state) do
    state = drain_terminal_messages(state)
    path = resolve_path(request.path, state.tool_cwd)

    with :ok <- ensure_approved(state, "fs/write_text_file", %{path: path}),
         :ok <- ensure_parent_dir(path),
         :ok <- File.write(path, request.content) do
      {:ok, %FsWriteTextFileResponse{}, state}
    else
      {:error, reason} when is_map(reason) -> {:error, reason, state}
      {:error, reason} -> {:error, io_error("fs/write_text_file failed", reason), state}
    end
  end

  @impl true
  def handle_terminal_create(%CreateRequest{} = request, state) do
    state = drain_terminal_messages(state)

    cwd =
      case request.cwd do
        value when is_binary(value) and value != "" -> resolve_path(value, state.tool_cwd)
        _ -> state.tool_cwd
      end

    args = request.args || []

    with :ok <-
           ensure_approved(state, "terminal/create", %{
             command: request.command,
             args: args,
             cwd: cwd
           }) do
      terminal_id = "term-" <> Integer.to_string(System.unique_integer([:positive]))
      env_pairs = normalize_env(request.env)
      output_limit = request.output_byte_limit || @default_terminal_output_limit

      owner = self()

      {worker_pid, monitor_ref} =
        spawn_monitor(fn ->
          result = run_terminal_command(request.command, args, cwd, env_pairs, output_limit)
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

      {:ok, %CreateResponse{terminal_id: terminal_id}, new_state}
    else
      {:error, reason} when is_map(reason) -> {:error, reason, state}
      {:error, reason} -> {:error, io_error("terminal/create failed", reason), state}
    end
  end

  @impl true
  def handle_terminal_output(%OutputRequest{} = request, state) do
    state = drain_terminal_messages(state)

    with {:ok, terminal} <- fetch_terminal(state, request.terminal_id) do
      response = %OutputResponse{
        output: terminal.output,
        truncated: terminal.truncated,
        exit_status: terminal_exit_status(terminal)
      }

      {:ok, response, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def handle_terminal_wait_for_exit(%WaitForExitRequest{} = request, state) do
    state = drain_terminal_messages(state)

    with {:ok, _terminal} <- fetch_terminal(state, request.terminal_id),
         {:ok, terminal, new_state} <-
           wait_for_terminal_exit(state, request.terminal_id, @terminal_wait_timeout_ms) do
      response = %WaitForExitResponse{exit_code: terminal.exit_code, signal: terminal.signal}
      {:ok, response, new_state}
    else
      {:error, reason, new_state} -> {:error, reason, new_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def handle_terminal_kill(%KillRequest{} = request, state) do
    state = drain_terminal_messages(state)

    with {:ok, terminal} <- fetch_terminal(state, request.terminal_id),
         :ok <- ensure_approved(state, "terminal/kill", %{terminal_id: request.terminal_id}) do
      if not terminal.done? and is_pid(terminal.worker_pid) and
           Process.alive?(terminal.worker_pid) do
        Process.exit(terminal.worker_pid, :kill)
      end

      new_state =
        complete_terminal(state, request.terminal_id, %{
          output: terminal.output,
          truncated: terminal.truncated,
          exit_code: terminal.exit_code,
          signal: terminal.signal || "SIGKILL"
        })

      {:ok, %KillResponse{}, new_state}
    else
      {:error, reason} when is_map(reason) -> {:error, reason, state}
      {:error, reason} -> {:error, io_error("terminal/kill failed", reason), state}
    end
  end

  @impl true
  def handle_terminal_release(%ReleaseRequest{} = request, state) do
    state = drain_terminal_messages(state)

    with {:ok, terminal} <- fetch_terminal(state, request.terminal_id) do
      if not terminal.done? and is_pid(terminal.worker_pid) and
           Process.alive?(terminal.worker_pid) do
        Process.exit(terminal.worker_pid, :kill)
      end

      new_state = delete_terminal(state, request.terminal_id, terminal.monitor_ref)
      {:ok, %ReleaseResponse{}, new_state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp default_approval(request, state) do
    CodexBridge.request_tool_approval(request,
      bridge_name: state.bridge,
      timeout: state.approval_timeout_ms
    )
  end

  defp ensure_approved(state, operation, details) do
    request = %{operation: operation, details: details}

    case state.approval_fun.(request, state) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error, %{code: -32003, message: "#{operation} denied by approval policy"}}

      {:error, reason} ->
        {:error, %{code: -32003, message: "#{operation} approval failed: #{inspect(reason)}"}}

      true ->
        :ok

      false ->
        {:error, %{code: -32003, message: "#{operation} denied by approval policy"}}

      other ->
        {:error,
         %{
           code: -32003,
           message: "#{operation} approval handler returned unexpected result: #{inspect(other)}"
         }}
    end
  end

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp resolve_path(path, cwd) do
    Path.expand(path, cwd)
  end

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
      name = item["name"] || item[:name]
      value = item["value"] || item[:value]

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
           %{code: -32002, message: "terminal/wait_for_exit timed out for #{terminal_id}"}, state}
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
      message ->
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
      message ->
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
      :error -> {:error, %{code: -32001, message: "terminal not found: #{terminal_id}"}}
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
    %{code: -32001, message: "#{message}: #{inspect(reason)}"}
  end
end
