defmodule Hivebeam.BridgeCatalog do
  @moduledoc false

  alias Hivebeam.CodexConfig

  @providers ["codex", "claude"]

  @spec providers() :: [%{provider: String.t(), bridge_name: atom()}]
  def providers do
    Enum.map(@providers, fn provider ->
      %{provider: provider, bridge_name: CodexConfig.bridge_name(provider)}
    end)
  end

  @spec provider_specs_for(String.t() | atom() | [String.t() | atom()] | nil) ::
          [%{provider: String.t(), bridge_name: atom()}]
  def provider_specs_for(nil), do: providers()
  def provider_specs_for([]), do: providers()

  def provider_specs_for(providers) when is_list(providers) do
    providers
    |> Enum.flat_map(&provider_specs_for/1)
    |> Enum.uniq_by(& &1.provider)
  end

  def provider_specs_for(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> provider_specs_for()
  end

  def provider_specs_for(provider) when is_binary(provider) do
    normalized =
      provider
      |> String.trim()
      |> String.downcase()

    providers()
    |> Enum.filter(&(&1.provider == normalized))
  end

  @spec target(node() | nil, atom()) :: map()
  def target(node, bridge_name) do
    %{
      node: node,
      bridge_name: bridge_name
    }
  end
end
