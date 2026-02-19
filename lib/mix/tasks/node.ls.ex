defmodule Mix.Tasks.Node.Ls do
  use Mix.Task

  alias Hivebeam.Inventory
  alias Hivebeam.NodeOrchestrator

  @shortdoc "Lists Hivebeam nodes or inspects one named node (native by default, --docker optional)"

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

    case NodeOrchestrator.ls(opts) do
      {:ok, %{projects: projects}} ->
        if projects == [] do
          Mix.shell().info("No hivebeam_* compose projects detected.")
        else
          Mix.shell().info("Docker projects:")
          Enum.each(projects, &Mix.shell().info("  - #{&1}"))
          Mix.shell().info("Use `mix node.ls --name <name>` for computed node details.")
        end

      {:ok, %{nodes: nodes}} ->
        if nodes == [] do
          Mix.shell().info("No native node pid files detected.")
        else
          Mix.shell().info("Native nodes:")

          Enum.each(nodes, fn node ->
            Mix.shell().info("  - #{node.name} status=#{node.status} pid=#{node.pid || "-"}")
          end)
        end

      {:ok, %{runtime: runtime, running: running, services: services}} ->
        state = if(running, do: "up", else: "down")

        inventory =
          Inventory.load()
          |> Inventory.update_runtime_state(runtime, state)

        _ = Inventory.save(inventory)

        mode = if(runtime.docker, do: "docker", else: "native")
        Mix.shell().info("Project: #{runtime.project_name}")
        Mix.shell().info("  mode: #{mode}")
        Mix.shell().info("  running: #{running}")
        Mix.shell().info("  node: #{runtime.node_name}")
        Mix.shell().info("  provider: #{runtime.provider}")
        Mix.shell().info("  remote: #{runtime.remote || "local"}")
        Mix.shell().info("  remote_path: #{runtime.remote_path}")
        Mix.shell().info("  bind_ip: #{runtime.bind_ip}")

        Mix.shell().info(
          "  ports: dist=#{runtime.dist_port} tcp=#{runtime.tcp_port} debug=#{runtime.debug_port} epmd=#{runtime.epmd_port}"
        )

        Mix.shell().info("  alias hint: --alias #{runtime.name}=#{runtime.node_name}")

        case services do
          [] ->
            :ok

          _ ->
            Mix.shell().info("  running services:")
            Enum.each(services, &Mix.shell().info("    - #{&1}"))
        end

      {:ok, %{runtime: runtime, running: running, status: status, pid: pid}} ->
        state =
          case status do
            "running" -> "up"
            "stopped" -> "down"
            _ -> "degraded"
          end

        inventory =
          Inventory.load()
          |> Inventory.update_runtime_state(runtime, state)

        _ = Inventory.save(inventory)

        mode = if(runtime.docker, do: "docker", else: "native")
        Mix.shell().info("Project: #{runtime.project_name}")
        Mix.shell().info("  mode: #{mode}")
        Mix.shell().info("  running: #{running}")
        Mix.shell().info("  status: #{status}")
        Mix.shell().info("  pid: #{pid || "-"}")
        Mix.shell().info("  node: #{runtime.node_name}")
        Mix.shell().info("  provider: #{runtime.provider}")
        Mix.shell().info("  remote: #{runtime.remote || "local"}")
        Mix.shell().info("  remote_path: #{runtime.remote_path}")
        Mix.shell().info("  pid_file: #{runtime.pid_file}")
        Mix.shell().info("  log_file: #{runtime.log_file}")
        Mix.shell().info("  alias hint: --alias #{runtime.name}=#{runtime.node_name}")

      {:error, {:compose_file_missing, path}} ->
        Mix.raise("Compose file not found: #{path}")

      {:error, {:remote_path_missing, reason}} ->
        Mix.raise(reason)

      {:error, {:command_failed, {cmd, cmd_args, code, output}}} ->
        Mix.raise(
          "Command failed (#{code}): #{cmd} #{Enum.join(cmd_args, " ")}\n#{String.trim(output)}"
        )

      {:error, reason} ->
        Mix.raise("Could not list nodes: #{inspect(reason)}")
    end
  end

  defp validate_invalid!([]), do: :ok

  defp validate_invalid!(invalid) do
    Mix.raise("Invalid options: #{Enum.map_join(invalid, ", ", &inspect/1)}")
  end
end
