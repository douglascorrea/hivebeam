defmodule Mix.Tasks.Hivebeam do
  use Mix.Task

  alias Hivebeam.DiscoveryManager
  alias Hivebeam.Inventory

  @shortdoc "Unified Hivebeam CLI entrypoint"

  @impl Mix.Task
  def run(args) do
    case args do
      ["host", "add" | rest] ->
        run_host_add(rest)

      ["host", "bootstrap" | rest] ->
        run_host_bootstrap(rest)

      ["discover", "sync" | rest] ->
        run_discover_sync(rest)

      ["targets", "ls" | rest] ->
        run_targets_ls(rest)

      ["chat" | rest] ->
        run_chat(rest)

      _ ->
        print_help()
    end
  end

  defp run_host_add(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [alias: :string, ssh: :string, remote_path: :string, tags: :string]
      )

    validate_invalid!(invalid)

    alias_name = required!(opts, :alias, "--alias")
    ssh = required!(opts, :ssh, "--ssh")

    tags =
      opts
      |> Keyword.get(:tags, "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    host = %{
      "alias" => alias_name,
      "ssh" => ssh,
      "remote_path" => Keyword.get(opts, :remote_path),
      "tags" => tags
    }

    inventory =
      host
      |> Inventory.upsert_host()

    case Inventory.save(inventory) do
      :ok ->
        Mix.shell().info("Saved host #{alias_name} (#{ssh})")

      {:error, reason} ->
        Mix.raise("Could not save inventory: #{inspect(reason)}")
    end
  end

  defp run_host_bootstrap(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [host: :string, remote: :string, version: :string, repo: :string]
      )

    validate_invalid!(invalid)

    remote =
      case Keyword.get(opts, :remote) do
        nil ->
          host_alias = required!(opts, :host, "--host or --remote")

          case Inventory.find_host(Inventory.load(), host_alias) do
            nil -> Mix.raise("Unknown host alias: #{host_alias}")
            host -> host["ssh"]
          end

        value ->
          value
      end

    version = Keyword.get(opts, :version, "latest")
    repo = Keyword.get(opts, :repo, "douglascorrea/hivebeam")

    install_command =
      "curl -fsSL https://raw.githubusercontent.com/#{repo}/refs/heads/master/install.sh | sh -s -- --version #{version}"

    case System.cmd("ssh", [remote, install_command], stderr_to_stdout: true) do
      {output, 0} -> Mix.shell().info(String.trim(output))
      {output, code} -> Mix.raise("Bootstrap failed (#{code}): #{String.trim(output)}")
    end
  end

  defp run_discover_sync(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [targets: :keep])
    validate_invalid!(invalid)

    selectors =
      opts
      |> Keyword.get_values(:targets)
      |> Enum.flat_map(&split_csv/1)

    case DiscoveryManager.sync_inventory(selectors: selectors) do
      {:ok, %{added_unmanaged: count, result: result}} ->
        Mix.shell().info("Discovery synced (mode=#{result.mode}); added unmanaged=#{count}")

      {:error, reason} ->
        Mix.raise("Discovery sync failed: #{inspect(reason)}")
    end
  end

  defp run_targets_ls(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [targets: :keep])
    validate_invalid!(invalid)

    selectors =
      opts
      |> Keyword.get_values(:targets)
      |> Enum.flat_map(&split_csv/1)

    result = DiscoveryManager.discover(selectors: selectors)

    Mix.shell().info("mode=#{result.mode} selectors=#{Enum.join(result.selectors, ",")}")

    if result.nodes == [] do
      Mix.shell().info("No targets discovered.")
    else
      Enum.each(result.nodes, fn node ->
        alias_name = Map.get(result.node_aliases, Atom.to_string(node), "-")
        Mix.shell().info("  - #{node} alias=#{alias_name}")
      end)
    end
  end

  defp run_chat(args) do
    Mix.Task.reenable("agents.live")

    normalized =
      case Enum.any?(args, fn arg -> String.starts_with?(arg, "--targets") end) do
        true -> args
        false -> ["--targets", "all" | args]
      end

    Mix.Tasks.Agents.Live.run(["--chat" | normalized])
  end

  defp split_csv(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
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

  defp print_help do
    Mix.shell().info("""
    Usage:
      mix hivebeam host add --alias <name> --ssh <user@host> [--remote-path <path>] [--tags a,b]
      mix hivebeam host bootstrap (--host <alias> | --remote <user@host>) [--version latest]
      mix hivebeam discover sync [--targets all|host:<alias>|tag:<tag>|provider:<name>|state:<state>]
      mix hivebeam targets ls [--targets ...]
      mix hivebeam chat [--targets ...] [other agents.live flags]
    """)
  end
end
