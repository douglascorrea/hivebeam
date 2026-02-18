defmodule ElxDockerNode.Codex do
  @moduledoc """
  Public API for distributed Codex ACP bridge calls.
  """

  alias ElxDockerNode.CodexBridge
  alias ElxDockerNode.CodexConfig

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

  @spec status(node() | nil) :: {:ok, map()} | {:error, term()}
  def status(target_node \\ nil)

  def status(nil), do: safe_local_call(fn -> CodexBridge.status() end)

  def status(target_node) when is_atom(target_node) do
    if target_node == Node.self() do
      status(nil)
    else
      timeout_ms = CodexConfig.connect_timeout_ms()
      safe_remote_call(fn -> :erpc.call(target_node, CodexBridge, :status, [], timeout_ms) end)
    end
  end

  @spec connected_nodes() :: [node()]
  def connected_nodes do
    Node.list()
  end

  @spec cancel(node() | nil) :: :ok | {:error, term()}
  def cancel(target_node \\ nil)

  def cancel(nil), do: safe_local_call(fn -> CodexBridge.cancel_prompt() end)

  def cancel(target_node) when is_atom(target_node) do
    if target_node == Node.self() do
      cancel(nil)
    else
      timeout_ms = CodexConfig.connect_timeout_ms()

      safe_remote_call(fn ->
        :erpc.call(target_node, CodexBridge, :cancel_prompt, [[]], timeout_ms)
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
