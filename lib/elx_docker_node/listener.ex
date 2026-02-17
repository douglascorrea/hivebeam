defmodule ElxDockerNode.Listener do
  @moduledoc false

  @listen_options [:binary, active: false, packet: 4, reuseaddr: true]
  @socket_timeout 5_000

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    with {:ok, name} <- fetch_name(opts),
         {:ok, port} <- fetch_port(opts) do
      on_message = Keyword.get(opts, :on_message, &default_on_message/1)
      parent = self()

      pid =
        spawn_link(fn ->
          case :gen_tcp.listen(port, @listen_options) do
            {:ok, listen_socket} ->
              send(parent, {:listener_ready, self()})
              accept_loop(listen_socket, name, on_message)

            {:error, reason} ->
              send(parent, {:listener_failed, self(), reason})
          end
        end)

      receive do
        {:listener_ready, ^pid} -> {:ok, pid}
        {:listener_failed, ^pid, reason} -> {:error, reason}
      after
        3_000 -> {:error, :startup_timeout}
      end
    end
  end

  defp accept_loop(listen_socket, node_name, on_message) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> handle_socket(socket, node_name, on_message) end)
        accept_loop(listen_socket, node_name, on_message)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        IO.warn("[#{node_name}] listener stopped: #{inspect(reason)}")
        :ok
    end
  end

  defp handle_socket(socket, node_name, on_message) do
    result =
      with {:ok, raw_payload} <- :gen_tcp.recv(socket, 0, @socket_timeout),
           {:ok, payload} <- decode_payload(raw_payload),
           :ok <- invoke_handler(on_message, payload),
           :ok <- :gen_tcp.send(socket, :erlang.term_to_binary({:ack, node_name})) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = :gen_tcp.send(socket, :erlang.term_to_binary({:error, inspect(reason)}))
        IO.warn("[#{node_name}] failed to process message: #{inspect(reason)}")
    end
  after
    :gen_tcp.close(socket)
  end

  defp decode_payload(raw_payload) do
    try do
      case :erlang.binary_to_term(raw_payload, [:safe]) do
        {:message, %{from: from, message: message, sent_at: sent_at} = payload}
        when is_binary(from) and is_binary(message) and is_binary(sent_at) ->
          {:ok, payload}

        other ->
          {:error, {:invalid_payload, other}}
      end
    rescue
      ArgumentError -> {:error, :invalid_payload}
    end
  end

  defp invoke_handler(on_message, payload) when is_function(on_message, 1) do
    case on_message.(payload) do
      :ok -> :ok
      other -> {:error, {:handler_error, other}}
    end
  end

  defp default_on_message(%{from: from, message: message, sent_at: sent_at}) do
    IO.puts("[received] #{from}: #{message} (sent at #{sent_at})")
    :ok
  end

  defp fetch_name(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, value} -> {:ok, to_string(value)}
      :error -> {:error, :missing_name}
    end
  end

  defp fetch_port(opts) do
    case Keyword.fetch(opts, :port) do
      {:ok, port} when is_integer(port) and port > 0 and port < 65_536 -> {:ok, port}
      {:ok, _invalid} -> {:error, :invalid_port}
      :error -> {:error, :missing_port}
    end
  end
end
