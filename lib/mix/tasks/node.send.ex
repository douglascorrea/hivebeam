defmodule Mix.Tasks.Node.Send do
  use Mix.Task

  @shortdoc "Sends a message to a TCP listener node"
  @switches [host: :string, port: :integer, from: :string, message: :string, timeout: :integer]
  @aliases [h: :host, p: :port, f: :from, m: :message, t: :timeout]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    validate_invalid!(invalid)

    host = required!(opts, :host, "--host")
    port = required!(opts, :port, "--port")
    from = required!(opts, :from, "--from")
    message = required!(opts, :message, "--message")
    timeout = Keyword.get(opts, :timeout, 5_000)

    case Hivebeam.send_message(host, port, from: from, message: message, timeout: timeout) do
      {:ok, remote_name} ->
        Mix.shell().info("Message delivered to '#{remote_name}' at #{host}:#{port}")

      {:error, reason} ->
        Mix.raise("Could not deliver message: #{inspect(reason)}")
    end
  end

  defp required!(opts, key, flag) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Mix.raise("Missing required option #{flag}")
    end
  end

  defp validate_invalid!([]), do: :ok

  defp validate_invalid!(invalid) do
    Mix.raise("Invalid options: #{Enum.map_join(invalid, ", ", &inspect/1)}")
  end
end
