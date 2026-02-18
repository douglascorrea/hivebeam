defmodule Mix.Tasks.Codex.Status do
  use Mix.Task

  @shortdoc "Shows local or remote Codex bridge status"
  @switches [node: :string]
  @aliases [n: :node]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    validate_invalid!(invalid)

    response =
      case Keyword.get(opts, :node) do
        nil -> Hivebeam.Codex.status(nil)
        node_string -> Hivebeam.Codex.status(String.to_atom(node_string))
      end

    case response do
      {:ok, status} ->
        Mix.shell().info(inspect(status, pretty: true, limit: :infinity))

      {:error, reason} ->
        Mix.raise("Could not fetch status: #{inspect(reason)}")
    end
  end

  defp validate_invalid!([]), do: :ok

  defp validate_invalid!(invalid) do
    Mix.raise("Invalid options: #{Enum.map_join(invalid, ", ", &inspect/1)}")
  end
end
