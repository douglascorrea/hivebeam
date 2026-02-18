defmodule Mix.Tasks.Agents.Live do
  use Mix.Task

  alias Hivebeam.BridgeCatalog
  alias Hivebeam.Codex
  alias Hivebeam.CodexChatUi
  alias Hivebeam.CodexCli
  alias Hivebeam.DiscoveryManager
  alias Hivebeam.Inventory

  @shortdoc "Realtime local/remote prompts using all available ACP bridges"

  @switches [
    alias: :keep,
    node: :keep,
    remote_ip: :keep,
    remote_self: :boolean,
    remote_name: :string,
    local: :boolean,
    message: :string,
    chat: :boolean,
    timeout: :integer,
    stream: :boolean,
    thoughts: :boolean,
    tools: :boolean,
    approve: :string,
    providers: :string,
    targets: :keep,
    name: :string,
    host_ip: :string,
    cookie: :string,
    dist_port: :integer,
    epmd: :string
  ]

  @aliases [
    n: :node,
    m: :message,
    t: :timeout,
    c: :cookie
  ]

  @discovery_attempts 15
  @discovery_delay_ms 200

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)
    validate_invalid!(invalid)

    approval_mode = CodexCli.parse_approval_mode!(Keyword.get(opts, :approve, "ask"))
    selectors = parse_target_selectors(opts)
    provider_specs = parse_provider_specs(opts, selectors.providers)
    {nodes, remote_nodes, discovered_aliases} = build_nodes(opts, selectors)
    target_aliases = parse_target_aliases(opts) |> Map.merge(discovered_aliases)

    ensure_distribution!(remote_nodes, opts)
    connect_remote_targets!(remote_nodes)

    targets = discover_targets(nodes, provider_specs, @discovery_attempts)

    if targets == [] do
      diagnostics = bridge_diagnostics(nodes, provider_specs)

      Mix.raise(
        "No available bridges found. Start remote with `mix agents.bridge.run` (or `mix codex.bridge.run` / `mix claude.bridge.run`) and retry.\n\n#{diagnostics}"
      )
    end

    prompt_opts = [
      timeout: Keyword.get(opts, :timeout),
      stream: Keyword.get(opts, :stream, true),
      show_thoughts: Keyword.get(opts, :thoughts, true),
      show_tools: Keyword.get(opts, :tools, true),
      approval_mode: approval_mode
    ]

    if Keyword.get(opts, :chat, false) do
      run_chat(targets, prompt_opts, Keyword.get(opts, :message), target_aliases)
    else
      message = required!(opts, :message, "--message")

      Enum.each(targets, fn target ->
        run_prompt!(target, message, prompt_opts)
      end)
    end
  end

  defp run_chat(targets, prompt_opts, first_message, target_aliases) do
    case CodexChatUi.run(targets, prompt_opts, first_message, target_aliases: target_aliases) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Mix.raise("Chat UI failed: #{inspect(reason)}")
    end
  end

  defp run_prompt!(target, message, prompt_opts) do
    Mix.shell().info("[#{target_label(target)}] prompt: #{message}")

    case CodexCli.prompt(target, message, prompt_opts) do
      {:ok, result} ->
        Mix.shell().info("[#{target_label(target)}] session_id=#{result.session_id}")
        Mix.shell().info("[#{target_label(target)}] stop_reason=#{result.stop_reason}")

      {:error, reason} ->
        Mix.raise("Prompt failed for #{target_label(target)}: #{inspect(reason)}")
    end
  end

  defp parse_provider_specs(opts, selector_providers) do
    providers =
      case Keyword.get(opts, :providers) do
        nil ->
          case selector_providers do
            [] -> nil
            selected -> selected
          end

        value ->
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
      end

    specs = BridgeCatalog.provider_specs_for(providers)

    if specs == [] do
      Mix.raise("No valid providers selected. Use --providers codex,claude")
    end

    specs
  end

  defp build_nodes(opts, selectors) do
    remote_name = Keyword.get(opts, :remote_name, "codex")
    remote_self? = Keyword.get(opts, :remote_self, false)

    explicit_nodes? =
      opts
      |> Keyword.get_values(:node)
      |> Enum.any?()

    explicit_remote_ips? =
      opts
      |> Keyword.get_values(:remote_ip)
      |> Enum.any?()

    if explicit_nodes? or explicit_remote_ips? or remote_self? do
      {nodes, remote_nodes} = build_explicit_nodes(opts, remote_name, remote_self?)
      {nodes, remote_nodes, %{}}
    else
      discovery = DiscoveryManager.discover(selectors: selectors.raw)
      include_local? = Keyword.get(opts, :local, false) or discovery.nodes == []

      nodes =
        if(include_local?, do: [nil], else: [])
        |> Kernel.++(discovery.nodes)
        |> Enum.uniq()

      {nodes, discovery.nodes, discovery.node_aliases}
    end
  end

  defp build_explicit_nodes(opts, remote_name, remote_self?) do
    nodes_from_flag =
      opts
      |> Keyword.get_values(:node)
      |> Enum.flat_map(&split_csv/1)
      |> Enum.map(&String.to_atom/1)

    nodes_from_ip =
      opts
      |> Keyword.get_values(:remote_ip)
      |> Enum.flat_map(&split_csv/1)
      |> Enum.map(fn ip -> String.to_atom("#{remote_name}@#{ip}") end)

    nodes_from_self =
      if remote_self? do
        host_ip = Keyword.get(opts, :host_ip) || detect_host_ip()
        [String.to_atom("#{remote_name}@#{host_ip}")]
      else
        []
      end

    remote_nodes = Enum.uniq(nodes_from_flag ++ nodes_from_ip ++ nodes_from_self)
    include_local? = Keyword.get(opts, :local, false) or remote_nodes == []

    nodes =
      if(include_local?, do: [nil], else: [])
      |> Kernel.++(remote_nodes)
      |> Enum.uniq()

    {nodes, remote_nodes}
  end

  defp discover_targets(nodes, provider_specs, attempts_left) do
    targets =
      nodes
      |> Enum.flat_map(fn node ->
        provider_specs
        |> Enum.flat_map(fn %{provider: _provider, bridge_name: bridge_name} ->
          case Codex.status(node, bridge_name: bridge_name) do
            {:ok, %{connected: true}} ->
              [BridgeCatalog.target(node, bridge_name)]

            _ ->
              []
          end
        end)
      end)
      |> Enum.uniq()

    cond do
      targets != [] ->
        targets

      attempts_left > 1 ->
        Process.sleep(@discovery_delay_ms)
        discover_targets(nodes, provider_specs, attempts_left - 1)

      true ->
        []
    end
  end

  defp bridge_diagnostics(nodes, provider_specs) do
    lines =
      nodes
      |> Enum.flat_map(fn node ->
        Enum.map(provider_specs, fn %{provider: provider, bridge_name: bridge_name} ->
          node_label = if(is_nil(node), do: "local", else: to_string(node))

          case Codex.status(node, bridge_name: bridge_name) do
            {:ok, status} ->
              last_error =
                case Map.get(status, :last_error) do
                  nil -> ""
                  reason -> " last_error=#{inspect(reason)}"
                end

              "  - #{node_label} [#{provider}] status=#{status.status} connected=#{status.connected}#{last_error}"

            {:error, reason} ->
              "  - #{node_label} [#{provider}] status_error=#{inspect(reason)}"
          end
        end)
      end)

    "Bridge diagnostics:\n" <> Enum.join(lines, "\n")
  end

  defp split_csv(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_target_selectors(opts) do
    raw =
      opts
      |> Keyword.get_values(:targets)
      |> Enum.flat_map(&split_csv/1)
      |> case do
        [] -> ["all"]
        values -> values
      end

    parsed = Inventory.parse_selectors(raw)
    %{raw: raw, providers: parsed.providers}
  end

  defp ensure_distribution!([], _opts), do: :ok

  defp ensure_distribution!(remote_targets, opts) do
    cookie = String.to_atom(Keyword.get(opts, :cookie, "hivebeam_cookie"))

    if Node.alive?() do
      Node.set_cookie(cookie)
    else
      epmd = Keyword.get(opts, :epmd, "127.0.0.1")
      host_ip = Keyword.get(opts, :host_ip) || detect_host_ip()
      node_label = Keyword.get(opts, :name, "host")
      dist_port = Keyword.get(opts, :dist_port, 9101)

      System.put_env("ERL_EPMD_ADDRESS", epmd)
      :application.set_env(:kernel, :inet_dist_listen_min, dist_port)
      :application.set_env(:kernel, :inet_dist_listen_max, dist_port)
      :application.set_env(:kernel, :connect_all, false)

      node_name = String.to_atom("#{node_label}@#{host_ip}")

      case Node.start(node_name, :longnames) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Mix.raise("Could not start distributed node #{node_name}: #{inspect(reason)}")
      end

      Node.set_cookie(cookie)

      Mix.shell().info("Distributed host node started as #{Node.self()}")
      Mix.shell().info("Using EPMD #{epmd} with distribution port #{dist_port}")
    end

    Mix.shell().info("Target remotes: #{Enum.map_join(remote_targets, ", ", &to_string/1)}")
  end

  defp connect_remote_targets!([]), do: :ok

  defp connect_remote_targets!(nodes) do
    Enum.each(nodes, fn node ->
      case Node.ping(node) do
        :pong -> Mix.shell().info("Connected to #{node}")
        :pang -> Mix.raise("Could not connect to remote node #{node}")
      end
    end)
  end

  defp detect_host_ip do
    with {:ok, ifaddrs} <- :inet.getifaddrs(),
         ip when not is_nil(ip) <- first_non_loopback_ipv4(ifaddrs) do
      ip
      |> :inet.ntoa()
      |> to_string()
    else
      _ -> "127.0.0.1"
    end
  end

  defp first_non_loopback_ipv4(ifaddrs) do
    Enum.find_value(ifaddrs, fn {_iface, attrs} ->
      flags = Keyword.get(attrs, :flags, [])

      if :up in flags do
        attrs
        |> Enum.filter(fn
          {:addr, ip} -> is_tuple(ip) and tuple_size(ip) == 4
          _ -> false
        end)
        |> Enum.map(fn {:addr, ip} -> ip end)
        |> Enum.find(fn {a, _, _, _} = ip ->
          ip != {127, 0, 0, 1} and a != 127
        end)
      else
        nil
      end
    end)
  end

  defp target_label(%{node: node, bridge_name: bridge_name}) do
    base =
      if(is_nil(node),
        do: if(Node.alive?(), do: to_string(Node.self()), else: "local"),
        else: to_string(node)
      )

    if to_string(bridge_name) in ["Elixir.Hivebeam.CodexBridge", "Hivebeam.CodexBridge"] do
      base
    else
      provider =
        bridge_name
        |> to_string()
        |> String.split(".")
        |> List.last()
        |> String.replace_suffix("Bridge", "")
        |> Macro.underscore()

      "#{base} [#{provider}]"
    end
  end

  defp parse_target_aliases(opts) do
    values =
      opts
      |> Keyword.get_values(:alias)
      |> Enum.flat_map(&split_csv/1)

    {node_to_alias, alias_to_node} =
      Enum.reduce(values, {%{}, %{}}, fn value, {node_acc, alias_acc} ->
        case String.split(value, "=", parts: 2) do
          [alias_name, node_name] ->
            alias_name = String.trim(alias_name)
            node_name = String.trim(node_name)

            cond do
              alias_name == "" or node_name == "" ->
                Mix.raise("Invalid --alias value #{inspect(value)}. Use --alias name=node@host")

              not valid_alias_name?(alias_name) ->
                Mix.raise("Invalid alias name #{inspect(alias_name)}. Use [A-Za-z0-9_.-]")

              Map.has_key?(alias_acc, alias_name) and Map.get(alias_acc, alias_name) != node_name ->
                Mix.raise("Alias #{inspect(alias_name)} maps to multiple nodes")

              true ->
                {Map.put(node_acc, node_name, alias_name),
                 Map.put(alias_acc, alias_name, node_name)}
            end

          _ ->
            Mix.raise("Invalid --alias value #{inspect(value)}. Use --alias name=node@host")
        end
      end)

    _ = alias_to_node
    node_to_alias
  end

  defp valid_alias_name?(value) do
    String.match?(value, ~r/^[A-Za-z0-9_.-]+$/)
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
