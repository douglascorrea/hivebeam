defmodule Hivebeam.DiscoveryManager do
  @moduledoc false

  alias Hivebeam.BridgeCatalog
  alias Hivebeam.CodexConfig
  alias Hivebeam.Inventory

  @type discovery_mode :: :inventory | :libcluster | :hybrid

  @spec mode() :: discovery_mode()
  def mode do
    case CodexConfig.discovery_mode() do
      "inventory" -> :inventory
      "libcluster" -> :libcluster
      _ -> :hybrid
    end
  end

  @spec discover(keyword()) :: %{
          mode: discovery_mode(),
          selectors: [String.t()],
          providers: [String.t()],
          nodes: [node()],
          inventory_nodes: [map()],
          unmanaged_nodes: [node()],
          node_aliases: %{String.t() => String.t()}
        }
  def discover(opts \\ []) do
    selectors = Keyword.get(opts, :selectors, ["all"]) |> normalize_selectors()
    parsed = Inventory.parse_selectors(selectors)

    providers =
      case parsed.providers do
        [] ->
          BridgeCatalog.providers()
          |> Enum.map(& &1.provider)

        selected ->
          selected
      end

    current_mode = normalize_mode(Keyword.get(opts, :mode, mode()))

    inventory_nodes =
      if current_mode in [:inventory, :hybrid] do
        Inventory.select_nodes(selectors)
      else
        []
      end

    inventory_runtime_nodes =
      inventory_nodes
      |> Enum.map(&parse_node_name/1)
      |> Enum.reject(&is_nil/1)

    runtime_nodes =
      if current_mode in [:libcluster, :hybrid] do
        discover_runtime_nodes()
      else
        []
      end

    unmanaged_nodes = runtime_nodes -- inventory_runtime_nodes

    nodes =
      (inventory_runtime_nodes ++ unmanaged_nodes)
      |> Enum.uniq()

    aliases = Inventory.node_aliases_for_targets(inventory_nodes)

    %{
      mode: current_mode,
      selectors: selectors,
      providers: providers,
      nodes: nodes,
      inventory_nodes: inventory_nodes,
      unmanaged_nodes: unmanaged_nodes,
      node_aliases: aliases
    }
  end

  @spec discover_targets(keyword()) :: [map()]
  def discover_targets(opts \\ []) do
    result = discover(opts)
    provider_specs = BridgeCatalog.provider_specs_for(result.providers)

    Enum.flat_map(result.nodes, fn node ->
      Enum.map(provider_specs, fn %{bridge_name: bridge_name} ->
        BridgeCatalog.target(node, bridge_name)
      end)
    end)
  end

  @spec sync_inventory(keyword()) :: {:ok, map()} | {:error, term()}
  def sync_inventory(opts \\ []) do
    result = discover(opts)
    inventory = Inventory.load()

    merged =
      Enum.reduce(result.unmanaged_nodes, inventory, fn node_name, acc ->
        node_name_string = Atom.to_string(node_name)

        Inventory.upsert_node(
          %{
            "name" => unmanaged_name(node_name_string),
            "host_alias" => unmanaged_host_alias(node_name_string),
            "provider" => "codex",
            "mode" => "native",
            "managed" => false,
            "node_name" => node_name_string,
            "state" => "up"
          },
          acc
        )
      end)

    case Inventory.save(merged) do
      :ok -> {:ok, %{added_unmanaged: length(result.unmanaged_nodes), result: result}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_selectors(selectors) when is_list(selectors) do
    selectors
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ["all"]
      values -> values
    end
  end

  defp normalize_mode(value) when is_atom(value) do
    case value do
      :inventory -> :inventory
      :libcluster -> :libcluster
      :hybrid -> :hybrid
      _ -> mode()
    end
  end

  defp normalize_mode(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "inventory" -> :inventory
      "libcluster" -> :libcluster
      "hybrid" -> :hybrid
      _ -> mode()
    end
  end

  defp normalize_mode(_), do: mode()

  defp parse_node_name(%{"node_name" => value}) when is_binary(value) do
    try do
      String.to_atom(value)
    rescue
      _ -> nil
    end
  end

  defp parse_node_name(_), do: nil

  defp discover_runtime_nodes do
    (Node.list() ++ CodexConfig.cluster_nodes())
    |> Enum.uniq()
  end

  defp unmanaged_name(node_name) do
    node_name
    |> String.split("@")
    |> List.first()
    |> Kernel.||("node")
  end

  defp unmanaged_host_alias(node_name) do
    node_name
    |> String.split("@")
    |> case do
      [_name, host] ->
        host

      _ ->
        "runtime"
    end
  end
end
