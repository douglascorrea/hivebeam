defmodule Hivebeam.CodexBridge do
  @moduledoc false

  alias Hivebeam.AgentBridge
  alias Hivebeam.CodexConfig

  @type status :: :connecting | :connected | :degraded
  @type approval_mode :: :ask | :allow | :deny

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    AgentBridge.start_link(opts,
      default_provider: "codex",
      default_bridge_name: CodexConfig.bridge_name("codex"),
      default_acp_command: CodexConfig.acp_command("codex")
    )
  end

  @spec prompt(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(prompt, opts \\ []) when is_binary(prompt) do
    bridge_name = Keyword.get(opts, :bridge_name, CodexConfig.bridge_name("codex"))

    timeout_ms =
      normalize_timeout_ms(Keyword.get(opts, :timeout), CodexConfig.prompt_timeout_ms()) + 5_000

    GenServer.call(bridge_name, {:prompt, prompt, opts}, timeout_ms)
  end

  @spec request_tool_approval(map(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def request_tool_approval(request, opts \\ []) when is_map(request) do
    bridge_name = Keyword.get(opts, :bridge_name, CodexConfig.bridge_name("codex"))

    timeout_ms =
      normalize_timeout_ms(Keyword.get(opts, :timeout), CodexConfig.prompt_timeout_ms())

    GenServer.call(bridge_name, {:tool_approval, request}, timeout_ms)
  end

  @spec cancel_prompt(keyword()) :: :ok | {:error, term()}
  def cancel_prompt(opts \\ []) do
    bridge_name = Keyword.get(opts, :bridge_name, CodexConfig.bridge_name("codex"))
    GenServer.call(bridge_name, :cancel_prompt)
  end

  @spec status() :: {:ok, map()}
  def status do
    status(CodexConfig.bridge_name("codex"))
  end

  @spec status(GenServer.server()) :: {:ok, map()}
  def status(server) do
    GenServer.call(server, :status, CodexConfig.connect_timeout_ms())
  end

  defp normalize_timeout_ms(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_timeout_ms(_value, default), do: default
end
