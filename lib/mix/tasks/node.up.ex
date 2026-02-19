defmodule Mix.Tasks.Node.Up do
  use Mix.Task

  alias Hivebeam.Inventory
  alias Hivebeam.NodeOrchestrator

  @shortdoc "Starts a named Hivebeam node locally or over SSH (native by default, --docker optional)"

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

    case NodeOrchestrator.up(opts) do
      {:ok, runtime, output} ->
        inventory =
          runtime
          |> Inventory.record_runtime()

        _ = Inventory.save(inventory)

        mode = if(runtime.docker, do: "docker", else: "native")
        Mix.shell().info("Started #{runtime.project_name} (mode=#{mode})")
        Mix.shell().info("  node: #{runtime.node_name}")
        Mix.shell().info("  provider: #{runtime.provider}")
        Mix.shell().info("  remote: #{runtime.remote || "local"}")
        Mix.shell().info("  remote_path: #{runtime.remote_path}")
        Mix.shell().info("  bind_ip: #{runtime.bind_ip}")

        Mix.shell().info(
          "  ports: dist=#{runtime.dist_port} tcp=#{runtime.tcp_port} debug=#{runtime.debug_port} epmd=#{runtime.epmd_port}"
        )

        Mix.shell().info("  alias hint: --alias #{runtime.name}=#{runtime.node_name}")
        if not runtime.docker, do: Mix.shell().info("  pid_file: #{runtime.pid_file}")
        if not runtime.docker, do: Mix.shell().info("  log_file: #{runtime.log_file}")

        trimmed = String.trim(output)
        if trimmed != "", do: Mix.shell().info(trimmed)

      {:error, {:missing_option, :name}} ->
        Mix.raise("Missing required option --name")

      {:error, {:target_resolution_failed, reason}} ->
        Mix.raise(reason)

      {:error, {:compose_file_missing, path}} ->
        Mix.raise("Compose file not found: #{path}")

      {:error, {:remote_path_missing, reason}} ->
        Mix.raise(reason)

      {:error, {:remote_bootstrap_failed, reason}} ->
        Mix.raise(reason)

      {:error, {:local_bind_ip_unavailable, bind_ip}} ->
        Mix.raise(
          "Local bind IP #{bind_ip} is not configured for Docker publishing. On macOS run: sudo ifconfig lo0 alias #{bind_ip} up"
        )

      {:error, {:command_failed, {cmd, cmd_args, code, output}}} ->
        Mix.raise(
          "Command failed (#{code}): #{cmd} #{Enum.join(cmd_args, " ")}\n#{String.trim(output)}"
        )

      {:error, reason} ->
        Mix.raise("Could not start node: #{inspect(reason)}")
    end
  end

  defp validate_invalid!([]), do: :ok

  defp validate_invalid!(invalid) do
    Mix.raise("Invalid options: #{Enum.map_join(invalid, ", ", &inspect/1)}")
  end
end
