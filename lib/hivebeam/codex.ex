defmodule Hivebeam.Codex do
  @moduledoc """
  Public API for distributed Codex ACP bridge calls.
  """

  alias Hivebeam.CodexBridge
  alias Hivebeam.CodexConfig

  @spec prompt(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(prompt, opts \\ []) when is_binary(prompt) do
    safe_local_call(fn -> CodexBridge.prompt(prompt, opts) end)
  end

  @spec prompt(node(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(target_node, prompt, opts) when is_atom(target_node) and is_binary(prompt) do
    if target_node == Node.self() do
      prompt(prompt, opts)
    else
      timeout_ms =
        normalize_timeout_ms(Keyword.get(opts, :timeout), CodexConfig.prompt_timeout_ms()) +
          10_000

      safe_remote_call(fn ->
        :erpc.call(target_node, CodexBridge, :prompt, [prompt, opts], timeout_ms)
      end)
    end
  end

  @spec status(node() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def status(target_node \\ nil, opts \\ [])

  def status(nil, opts) do
    bridge_name = Keyword.get(opts, :bridge_name, CodexConfig.bridge_name())
    safe_local_call(fn -> CodexBridge.status(bridge_name) end)
  end

  def status(target_node, opts) when is_atom(target_node) do
    if target_node == Node.self() do
      status(nil, opts)
    else
      timeout_ms =
        normalize_timeout_ms(Keyword.get(opts, :timeout), CodexConfig.connect_timeout_ms())

      bridge_name = Keyword.get(opts, :bridge_name, CodexConfig.bridge_name())

      safe_remote_call(fn ->
        :erpc.call(target_node, CodexBridge, :status, [bridge_name], timeout_ms)
      end)
    end
  end

  @spec connected_nodes() :: [node()]
  def connected_nodes do
    Node.list()
  end

  @spec cancel(node() | nil, keyword()) :: :ok | {:error, term()}
  def cancel(target_node \\ nil, opts \\ [])

  def cancel(nil, opts), do: safe_local_call(fn -> CodexBridge.cancel_prompt(opts) end)

  def cancel(target_node, opts) when is_atom(target_node) do
    if target_node == Node.self() do
      cancel(nil, opts)
    else
      timeout_ms =
        normalize_timeout_ms(Keyword.get(opts, :timeout), CodexConfig.connect_timeout_ms())

      safe_remote_call(fn ->
        :erpc.call(target_node, CodexBridge, :cancel_prompt, [opts], timeout_ms)
      end)
    end
  end

  defp safe_local_call(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:bridge_unavailable, reason}}
  end

  defp safe_remote_call(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:remote_call_failed, reason}}
  end

  defp normalize_timeout_ms(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_timeout_ms(_value, default), do: default
end
