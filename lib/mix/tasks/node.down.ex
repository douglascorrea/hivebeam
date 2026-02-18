defmodule Mix.Tasks.Node.Down do
  use Mix.Task

  alias Hivebeam.NodeOrchestrator

  @shortdoc "Stops a named Hivebeam node locally or over SSH (native by default, --docker optional)"

  @switches [
    docker: :boolean,
    name: :string,
    provider: :string,
    slot: :integer,
    remote: :string,
    remote_path: :string,
    host_ip: :string,
    bind_ip: :string,
    cookie: :string,
    dist_port: :integer,
    tcp_port: :integer,
    debug_port: :integer,
    epmd_port: :integer
  ]

  @aliases [n: :name]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    validate_invalid!(invalid)

    case NodeOrchestrator.down(opts) do
      {:ok, runtime, output} ->
        mode = if(runtime.docker, do: "docker", else: "native")
        Mix.shell().info("Stopped #{runtime.project_name} (mode=#{mode})")
        trimmed = String.trim(output)
        if trimmed != "", do: Mix.shell().info(trimmed)

      {:error, {:missing_option, :name}} ->
        Mix.raise("Missing required option --name")

      {:error, {:compose_file_missing, path}} ->
        Mix.raise("Compose file not found: #{path}")

      {:error, {:remote_path_missing, reason}} ->
        Mix.raise(reason)

      {:error, {:command_failed, {cmd, cmd_args, code, output}}} ->
        Mix.raise(
          "Command failed (#{code}): #{cmd} #{Enum.join(cmd_args, " ")}\n#{String.trim(output)}"
        )

      {:error, reason} ->
        Mix.raise("Could not stop node: #{inspect(reason)}")
    end
  end

  defp validate_invalid!([]), do: :ok

  defp validate_invalid!(invalid) do
    Mix.raise("Invalid options: #{Enum.map_join(invalid, ", ", &inspect/1)}")
  end
end
