defmodule Hivebeam do
  @moduledoc """
  Tiny TCP-based node-to-node messaging for local host + Docker demos.
  """

  alias Hivebeam.Listener

  @type send_option ::
          {:from, String.t()}
          | {:message, String.t()}
          | {:timeout, timeout()}

  @doc """
  Starts a node listener on the given TCP port.

  Required options:
    * `:name` - label shown in logs and acknowledgements
    * `:port` - TCP port to listen on

  Optional options:
    * `:on_message` - callback receiving `%{from, message, sent_at}`
  """
  @spec start_node(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_node(opts) do
    Listener.start_link(opts)
  end

  @doc """
  Sends a message to another node listener.

  Required options:
    * `:from`
    * `:message`

  Optional options:
    * `:timeout` (defaults to `5_000`)
  """
  @spec send_message(String.t(), pos_integer(), [send_option()]) ::
          {:ok, String.t()} | {:error, term()}
  def send_message(host, port, opts) when is_binary(host) and is_integer(port) do
    with {:ok, from} <- Keyword.fetch(opts, :from),
         {:ok, message} <- Keyword.fetch(opts, :message),
         {:ok, socket} <-
           :gen_tcp.connect(String.to_charlist(host), port, tcp_options(), timeout(opts)) do
      payload = %{
        from: to_string(from),
        message: to_string(message),
        sent_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      result =
        with :ok <- :gen_tcp.send(socket, :erlang.term_to_binary({:message, payload})),
             {:ok, raw_reply} <- :gen_tcp.recv(socket, 0, timeout(opts)),
             {:ok, remote_name} <- decode_ack(raw_reply) do
          {:ok, remote_name}
        end

      :ok = :gen_tcp.close(socket)
      result
    else
      :error -> {:error, :missing_required_options}
      {:error, _reason} = error -> error
    end
  end

  defp decode_ack(raw_reply) do
    try do
      case :erlang.binary_to_term(raw_reply, [:safe]) do
        {:ack, remote_name} when is_binary(remote_name) -> {:ok, remote_name}
        other -> {:error, {:unexpected_reply, other}}
      end
    rescue
      ArgumentError -> {:error, :invalid_reply}
    end
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, 5_000)

  defp tcp_options do
    [:binary, active: false, packet: 4]
  end
end
