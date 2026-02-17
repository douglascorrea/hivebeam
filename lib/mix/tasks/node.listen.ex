defmodule Mix.Tasks.Node.Listen do
  use Mix.Task

  @shortdoc "Starts a TCP listener node"
  @switches [name: :string, port: :integer]
  @aliases [n: :name, p: :port]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    validate_invalid!(invalid)

    name = required!(opts, :name, "--name")
    port = required!(opts, :port, "--port")

    case ElxDockerNode.start_node(name: name, port: port) do
      {:ok, _pid} ->
        Mix.shell().info("Node '#{name}' listening on port #{port}")
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("Could not start listener: #{inspect(reason)}")
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
