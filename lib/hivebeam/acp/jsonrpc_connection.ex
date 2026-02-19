defmodule Hivebeam.Acp.JsonRpcConnection do
  @moduledoc false
  use GenServer

  alias Hivebeam.Acp.TransportNdjson

  @default_request_timeout 120_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec send_request(pid(), String.t(), map(), pos_integer()) :: map()
  def send_request(conn_pid, method, params, timeout_ms \\ @default_request_timeout)
      when is_pid(conn_pid) and is_binary(method) and is_map(params) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    GenServer.call(conn_pid, {:request, method, params, timeout_ms}, timeout_ms + 1_000)
  catch
    :exit, reason ->
      %{"error" => %{code: -32_000, message: "request exited", reason: inspect(reason)}}
  end

  @spec send_notification(pid(), String.t(), map()) :: :ok | {:error, term()}
  def send_notification(conn_pid, method, params)
      when is_pid(conn_pid) and is_binary(method) and is_map(params) do
    GenServer.call(conn_pid, {:notification, method, params})
  catch
    :exit, reason ->
      {:error, {:notification_exited, reason}}
  end

  @impl true
  def init(opts) do
    handler_module = Keyword.fetch!(opts, :handler_module)
    handler_args = Keyword.get(opts, :handler_args, [])
    agent_path = Keyword.fetch!(opts, :agent_path)
    agent_args = Keyword.get(opts, :agent_args, [])

    with {:ok, handler_state} <- handler_module.init(handler_args),
         {:ok, port} <- TransportNdjson.open_port(agent_path, agent_args) do
      state = %{
        port: port,
        buffer: "",
        next_id: 1,
        pending: %{},
        handler_module: handler_module,
        handler_state: handler_state,
        closed_reason: nil
      }

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, method, params, timeout_ms}, from, state) do
    id = state.next_id

    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    case send_json(state, message) do
      :ok ->
        timer_ref = Process.send_after(self(), {:request_timeout, id}, timeout_ms)

        pending =
          Map.put(state.pending, id, %{from: from, timer_ref: timer_ref, method: method})

        {:noreply, %{state | next_id: id + 1, pending: pending}}

      {:error, reason} ->
        {:reply,
         %{"error" => %{code: -32_000, message: "request send failed", reason: inspect(reason)}},
         state}
    end
  end

  def handle_call({:notification, method, params}, _from, state) do
    message = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    }

    {:reply, send_json(state, message), state}
  end

  @impl true
  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        {:noreply, %{state | pending: pending}}

      {%{from: from}, pending} ->
        GenServer.reply(
          from,
          %{
            "error" => %{
              code: -32_002,
              message: "request timed out",
              request_id: id
            }
          }
        )

        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    {messages, buffer} = TransportNdjson.decode_lines(state.buffer, data)
    state = %{state | buffer: buffer}

    next_state =
      Enum.reduce(messages, state, fn message, acc ->
        handle_incoming_message(message, acc)
      end)

    {:noreply, next_state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = {:port_exit_status, status}
    {:stop, reason, drain_pending(state, reason)}
  end

  def handle_info(message, state) do
    handler_module = state.handler_module

    if function_exported?(handler_module, :handle_info, 2) do
      case handler_module.handle_info(message, state.handler_state) do
        {:noreply, new_handler_state} ->
          {:noreply, %{state | handler_state: new_handler_state}}

        {:stop, reason, new_handler_state} ->
          {:stop, reason, %{state | handler_state: new_handler_state}}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    _ = drain_pending(state, reason)

    if is_port(state.port) do
      Port.close(state.port)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp handle_incoming_message(%{"id" => id} = message, state)
       when is_integer(id) or is_binary(id) do
    cond do
      Map.has_key?(message, "result") or Map.has_key?(message, "error") ->
        handle_response(id, message, state)

      Map.has_key?(message, "method") ->
        handle_request(message, state)

      true ->
        state
    end
  end

  defp handle_incoming_message(%{"method" => _method} = message, state) do
    handle_notification(message, state)
  end

  defp handle_incoming_message(_message, state), do: state

  defp handle_response(id, message, state) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        %{state | pending: pending}

      {%{from: from, timer_ref: timer_ref}, pending} ->
        _ = Process.cancel_timer(timer_ref)

        cond do
          Map.has_key?(message, "result") ->
            GenServer.reply(from, %{"result" => Map.get(message, "result")})

          Map.has_key?(message, "error") ->
            GenServer.reply(from, %{"error" => Map.get(message, "error")})

          true ->
            GenServer.reply(
              from,
              %{"error" => %{code: -32_000, message: "invalid response", response: message}}
            )
        end

        %{state | pending: pending}
    end
  end

  defp handle_request(%{"id" => id, "method" => method} = message, state)
       when is_binary(method) do
    params = Map.get(message, "params", %{})

    {response, new_state} = invoke_request_handler(method, params, state)

    encoded_response =
      case response do
        {:ok, result} ->
          %{"jsonrpc" => "2.0", "id" => id, "result" => result}

        {:error, error} ->
          %{"jsonrpc" => "2.0", "id" => id, "error" => error}

        :noreply ->
          nil
      end

    if is_map(encoded_response) do
      _ = send_json(new_state, encoded_response)
    end

    new_state
  end

  defp handle_request(_message, state), do: state

  defp handle_notification(%{"method" => method} = message, state) when is_binary(method) do
    params = Map.get(message, "params", %{})
    handler_module = state.handler_module

    case handler_module.handle_notification(method, params, state.handler_state) do
      {:noreply, new_handler_state} ->
        %{state | handler_state: new_handler_state}

      _ ->
        state
    end
  rescue
    _ ->
      state
  end

  defp handle_notification(_message, state), do: state

  defp invoke_request_handler(method, params, state) do
    handler_module = state.handler_module

    case handler_module.handle_request(method, params, state.handler_state) do
      {:ok, result, new_handler_state} when is_map(result) ->
        {{:ok, result}, %{state | handler_state: new_handler_state}}

      {:error, error, new_handler_state} when is_map(error) ->
        {{:error, error}, %{state | handler_state: new_handler_state}}

      {:noreply, new_handler_state} ->
        {:noreply, %{state | handler_state: new_handler_state}}

      other ->
        error = %{code: -32_000, message: "invalid handler return", details: inspect(other)}
        {{:error, error}, state}
    end
  rescue
    error ->
      details = Exception.format(:error, error, __STACKTRACE__)

      {{:error, %{code: -32_000, message: "handler crashed", details: details}}, state}
  end

  defp send_json(state, payload) do
    case state.closed_reason do
      nil -> TransportNdjson.send_message(state.port, payload)
      reason -> {:error, {:connection_closed, reason}}
    end
  end

  defp drain_pending(state, reason) do
    Enum.each(state.pending, fn {id, %{from: from, timer_ref: timer_ref}} ->
      _ = Process.cancel_timer(timer_ref)

      GenServer.reply(
        from,
        %{
          "error" => %{
            code: -32_000,
            message: "connection closed",
            request_id: id,
            reason: inspect(reason)
          }
        }
      )
    end)

    %{state | pending: %{}, closed_reason: reason}
  end
end
