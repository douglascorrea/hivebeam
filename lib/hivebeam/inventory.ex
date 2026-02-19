defmodule Hivebeam.Inventory do
  @moduledoc false

  alias Hivebeam.ConfigStore
  alias Hivebeam.TomlLite

  @type host_entry :: map()
  @type node_entry :: map()
  @type inventory :: map()

  @spec path() :: String.t()
  def path do
    System.get_env("HIVEBEAM_INVENTORY_PATH") || Path.join([config_root(), "nodes.toml"])
  end

  @spec load() :: inventory()
  def load do
    case File.read(path()) do
      {:ok, raw} ->
        case TomlLite.decode(raw) do
          {:ok, decoded} when is_map(decoded) -> normalize(decoded)
          _ -> empty_inventory()
        end

      _ ->
        empty_inventory()
    end
  end

  @spec save(inventory()) :: :ok | {:error, term()}
  def save(inventory) when is_map(inventory) do
    normalized = normalize(inventory)

    with :ok <- File.mkdir_p(config_root()) do
      File.write(path(), TomlLite.encode(normalized))
    end
  end

  @spec upsert_host(map(), inventory() | nil) :: inventory()
  def upsert_host(host_attrs, inventory \\ nil) when is_map(host_attrs) do
    inventory = inventory || load()

    host = normalize_host(host_attrs)
    key = host["alias"]

    hosts =
      inventory
      |> Map.get("hosts", [])
      |> Enum.reject(&(&1["alias"] == key))
      |> Kernel.++([host])
      |> Enum.sort_by(& &1["alias"])

    Map.put(inventory, "hosts", hosts)
  end

  @spec upsert_node(map(), inventory() | nil) :: inventory()
  def upsert_node(node_attrs, inventory \\ nil) when is_map(node_attrs) do
    inventory = inventory || load()

    node = normalize_node(node_attrs)
    key = node_key(node)

    nodes =
      inventory
      |> Map.get("nodes", [])
      |> Enum.reject(&(node_key(&1) == key))
      |> Kernel.++([node])
      |> Enum.sort_by(&{&1["host_alias"], &1["name"]})

    Map.put(inventory, "nodes", nodes)
  end

  @spec record_runtime(map(), inventory() | nil) :: inventory()
  def record_runtime(runtime, inventory \\ nil) when is_map(runtime) do
    inventory = inventory || load()

    {host_alias, inventory} =
      case runtime.remote do
        nil ->
          {"local",
           upsert_host(%{"alias" => "local", "ssh" => "local", "tags" => ["local"]}, inventory)}

        remote ->
          existing = find_host(inventory, remote)

          host =
            existing ||
              %{
                "alias" => host_alias_from_remote(remote),
                "ssh" => remote,
                "remote_path" => runtime.remote_path,
                "tags" => ["remote"]
              }

          {host["alias"], upsert_host(host, inventory)}
      end

    node = %{
      "name" => to_string(runtime.name),
      "host_alias" => host_alias,
      "provider" => to_string(runtime.provider),
      "mode" => if(runtime.docker, do: "docker", else: "native"),
      "managed" => true,
      "node_name" => to_string(runtime.node_name),
      "state" => "up"
    }

    upsert_node(node, inventory)
  end

  @spec update_runtime_state(map(), String.t(), inventory() | nil) :: inventory()
  @spec update_runtime_state(inventory(), map(), String.t()) :: inventory()
  def update_runtime_state(first, second, third \\ nil)

  def update_runtime_state(runtime, state, inventory)
      when is_map(runtime) and is_binary(state) do
    do_update_runtime_state(runtime, state, inventory || load())
  end

  def update_runtime_state(inventory, runtime, state)
      when is_map(inventory) and is_map(runtime) and is_binary(state) do
    do_update_runtime_state(runtime, state, inventory)
  end

  defp do_update_runtime_state(runtime, state, inventory) do
    inventory = inventory || load()

    name = runtime_value(runtime, :name, "name")
    provider = runtime_value(runtime, :provider, "provider")

    host_alias =
      case runtime_value(runtime, :remote, "remote") do
        nil ->
          "local"

        remote ->
          host_alias_for_remote(remote, inventory) || host_alias_from_remote(remote)
      end

    state = normalize_string(state, "down")

    nodes =
      inventory
      |> Map.get("nodes", [])
      |> Enum.map(fn node ->
        if node["name"] == name and node["host_alias"] == host_alias and
             node["provider"] == provider do
          Map.put(node, "state", state)
        else
          node
        end
      end)

    Map.put(inventory, "nodes", nodes)
  end

  @spec hosts(inventory() | nil) :: [host_entry()]
  def hosts(inventory \\ nil) do
    (inventory || load())
    |> Map.get("hosts", [])
  end

  @spec nodes(inventory() | nil) :: [node_entry()]
  def nodes(inventory \\ nil) do
    (inventory || load())
    |> Map.get("nodes", [])
  end

  @spec find_host(inventory(), String.t()) :: host_entry() | nil
  def find_host(inventory, lookup) when is_map(inventory) and is_binary(lookup) do
    value = String.trim(lookup)

    hosts(inventory)
    |> Enum.find(fn host ->
      host["alias"] == value or host["ssh"] == value
    end)
  end

  @spec host_alias_for_remote(String.t(), inventory() | nil) :: String.t() | nil
  def host_alias_for_remote(remote, inventory \\ nil) when is_binary(remote) do
    case find_host(inventory || load(), remote) do
      nil -> nil
      host -> host["alias"]
    end
  end

  @spec remote_path_for_remote(String.t(), inventory() | nil) :: String.t() | nil
  def remote_path_for_remote(remote, inventory \\ nil) when is_binary(remote) do
    case find_host(inventory || load(), remote) do
      nil -> nil
      host -> host["remote_path"]
    end
  end

  @spec node_aliases_for_targets([node_entry()]) :: %{String.t() => String.t()}
  def node_aliases_for_targets(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      node_name = entry["node_name"] || ""
      alias_name = entry["name"] || ""

      if node_name != "" and alias_name != "" do
        Map.put_new(acc, node_name, alias_name)
      else
        acc
      end
    end)
  end

  @spec select_nodes([String.t()], inventory() | nil) :: [node_entry()]
  def select_nodes(selectors, inventory \\ nil) when is_list(selectors) do
    inventory = inventory || load()
    parsed = parse_selectors(selectors)

    host_map =
      hosts(inventory)
      |> Map.new(fn host ->
        {host["alias"], host}
      end)

    inventory
    |> nodes()
    |> Enum.filter(fn node ->
      matches_provider?(node, parsed.providers) and
        matches_host?(node, parsed.hosts) and
        matches_tag?(node, host_map, parsed.tags) and
        matches_state?(node, parsed.states)
    end)
  end

  @spec parse_selectors([String.t()]) :: %{
          providers: [String.t()],
          hosts: [String.t()],
          tags: [String.t()],
          states: [String.t()]
        }
  def parse_selectors(selectors) when is_list(selectors) do
    selectors
    |> Enum.reduce(%{providers: [], hosts: [], tags: [], states: []}, fn selector, acc ->
      selector
      |> to_string()
      |> String.trim()
      |> case do
        "" ->
          acc

        "all" ->
          acc

        "provider:" <> provider ->
          %{acc | providers: Enum.uniq(acc.providers ++ [String.trim(provider)])}

        "host:" <> host_alias ->
          %{acc | hosts: Enum.uniq(acc.hosts ++ [String.trim(host_alias)])}

        "tag:" <> tag ->
          %{acc | tags: Enum.uniq(acc.tags ++ [String.trim(tag)])}

        "state:" <> state ->
          %{acc | states: Enum.uniq(acc.states ++ [String.trim(state)])}

        _ ->
          acc
      end
    end)
  end

  @spec ensure_default_files() :: :ok | {:error, term()}
  def ensure_default_files do
    with :ok <- File.mkdir_p(config_root()) do
      if File.exists?(path()) do
        :ok
      else
        save(empty_inventory())
      end
    end
  end

  defp node_key(node) do
    "#{node["host_alias"]}:#{node["name"]}:#{node["provider"]}"
  end

  defp normalize(map) do
    %{
      "hosts" => map |> Map.get("hosts", []) |> Enum.map(&normalize_host/1),
      "nodes" => map |> Map.get("nodes", []) |> Enum.map(&normalize_node/1)
    }
  end

  defp normalize_host(host) do
    %{
      "alias" => normalize_string(Map.get(host, "alias"), ""),
      "ssh" => normalize_string(Map.get(host, "ssh"), ""),
      "remote_path" =>
        normalize_string(
          Map.get(host, "remote_path"),
          ConfigStore.default_remote_path()
        ),
      "tags" => normalize_tags(Map.get(host, "tags", []))
    }
  end

  defp normalize_node(node) do
    %{
      "name" => normalize_string(Map.get(node, "name"), ""),
      "host_alias" => normalize_string(Map.get(node, "host_alias"), ""),
      "provider" => normalize_string(Map.get(node, "provider"), "codex"),
      "mode" => normalize_string(Map.get(node, "mode"), "native"),
      "managed" => normalize_bool(Map.get(node, "managed"), true),
      "node_name" => normalize_string(Map.get(node, "node_name"), ""),
      "state" => normalize_string(Map.get(node, "state"), "up")
    }
  end

  defp normalize_string(value, default) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: default, else: trimmed
  end

  defp normalize_string(nil, default), do: default
  defp normalize_string(value, default), do: normalize_string(to_string(value), default)

  defp normalize_bool(value, _default) when is_boolean(value), do: value

  defp normalize_bool(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp normalize_bool(_value, default), do: default

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",")
    |> normalize_tags()
  end

  defp normalize_tags(_), do: []

  defp runtime_value(runtime, atom_key, string_key) do
    runtime
    |> Map.get(atom_key, Map.get(runtime, string_key))
    |> normalize_string("")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp empty_inventory do
    %{"hosts" => [], "nodes" => []}
  end

  defp matches_provider?(_node, []), do: true

  defp matches_provider?(node, providers) do
    node["provider"] in providers
  end

  defp matches_host?(_node, []), do: true

  defp matches_host?(node, hosts) do
    node["host_alias"] in hosts
  end

  defp matches_tag?(_node, _host_map, []), do: true

  defp matches_tag?(node, host_map, tags) do
    host_tags =
      case Map.get(host_map, node["host_alias"]) do
        nil -> []
        host -> host["tags"] || []
      end

    Enum.any?(tags, &(&1 in host_tags))
  end

  defp matches_state?(_node, []), do: true

  defp matches_state?(node, states) do
    node["state"] in states
  end

  defp host_alias_from_remote(remote) do
    remote
    |> String.split("@")
    |> List.last()
    |> String.replace(~r/[^a-zA-Z0-9_.-]/, "-")
  end

  defp config_root do
    System.get_env("HIVEBEAM_CONFIG_ROOT") ||
      Path.join([System.user_home!(), ".config", "hivebeam"])
  end
end
