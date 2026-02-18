defmodule Hivebeam.CodexCli do
  @moduledoc false

  alias Hivebeam.Codex
  alias Hivebeam.CodexStream

  @stream_poll_ms 50

  @spec prompt(node() | nil, String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(target_node, message, opts \\ []) when is_binary(message) do
    shell = Keyword.get(opts, :shell, Mix.shell())
    timeout = Keyword.get(opts, :timeout)
    stream? = Keyword.get(opts, :stream, true)
    show_thoughts? = Keyword.get(opts, :show_thoughts, true)
    show_tools? = Keyword.get(opts, :show_tools, true)
    approval_mode = parse_approval_mode(Keyword.get(opts, :approval_mode, :ask))

    caller_pid = self()

    call_opts =
      []
      |> maybe_put_timeout(timeout)
      |> maybe_put_stream_target(stream?, caller_pid)
      |> maybe_put_approval(approval_mode, caller_pid)

    task = Task.async(fn -> call_prompt(target_node, message, call_opts) end)

    state = %{
      shell: shell,
      show_thoughts?: show_thoughts?,
      show_tools?: show_tools?,
      approval_mode: approval_mode
    }

    await_prompt_result(task, state)
  end

  @spec parse_approval_mode(term()) :: :ask | :allow | :deny
  def parse_approval_mode(:ask), do: :ask
  def parse_approval_mode(:allow), do: :allow
  def parse_approval_mode(:deny), do: :deny
  def parse_approval_mode("ask"), do: :ask
  def parse_approval_mode("allow"), do: :allow
  def parse_approval_mode("deny"), do: :deny
  def parse_approval_mode(_), do: :ask

  @spec parse_approval_mode!(String.t() | atom()) :: :ask | :allow | :deny
  def parse_approval_mode!(mode) do
    parsed = parse_approval_mode(mode)

    if mode in [:ask, :allow, :deny, "ask", "allow", "deny"] do
      parsed
    else
      raise ArgumentError, "invalid approval mode #{inspect(mode)} (expected ask|allow|deny)"
    end
  end

  defp await_prompt_result(task, state) do
    receive do
      {:codex_prompt_stream, payload} ->
        render_prompt_stream(payload, state)
        await_prompt_result(task, state)

      {:codex_tool_approval_request, payload} ->
        reply_tool_approval(payload, state)
        await_prompt_result(task, state)
    after
      @stream_poll_ms ->
        case Task.yield(task, 0) do
          {:ok, result} ->
            flush_inbox(state)
            result

          nil ->
            await_prompt_result(task, state)
        end
    end
  end

  defp flush_inbox(state) do
    receive do
      {:codex_prompt_stream, payload} ->
        render_prompt_stream(payload, state)
        flush_inbox(state)

      {:codex_tool_approval_request, payload} ->
        reply_tool_approval(payload, state)
        flush_inbox(state)
    after
      0 ->
        :ok
    end
  end

  defp render_prompt_stream(payload, state) do
    case fetch(payload, :event) do
      event when event in [:start, "start", :done, "done"] ->
        :ok

      event when event in [:error, "error"] ->
        reason = fetch(payload, :reason)
        state.shell.error("Prompt stream error: #{inspect(reason)}")

      event when event in [:update, "update"] ->
        render_update(fetch(payload, :update), fetch(payload, :node), state)

      _ ->
        :ok
    end
  end

  defp render_update(update, node_name, state) when is_map(update) do
    kind = CodexStream.update_kind(update)
    node_label = node_name |> to_string()

    cond do
      kind == "agent_thought_chunk" and state.show_thoughts? ->
        update
        |> CodexStream.thought_chunks()
        |> Enum.each(fn chunk -> state.shell.info("[#{node_label} thought] #{chunk}") end)

      kind == "agent_message_chunk" ->
        update
        |> CodexStream.message_chunks()
        |> Enum.each(fn chunk -> state.shell.info("[#{node_label}] #{chunk}") end)

      kind in ["tool_call", "tool_call_update"] and state.show_tools? ->
        activity = CodexStream.tool_activity(update)
        state.shell.info("[#{node_label} tool] #{activity}: #{CodexStream.tool_summary(update)}")

      true ->
        :ok
    end
  end

  defp render_update(_update, _node_name, _state), do: :ok

  defp reply_tool_approval(payload, state) do
    ref = fetch(payload, :ref)
    reply_to = fetch(payload, :reply_to)

    if is_reference(ref) and is_pid(reply_to) do
      decision =
        case state.approval_mode do
          :allow -> true
          :deny -> false
          :ask -> state.shell.yes?(approval_prompt(payload))
        end

      send(reply_to, {:codex_tool_approval_reply, ref, decision})
    end
  end

  defp approval_prompt(payload) do
    node_name = fetch(payload, :node)
    request = fetch(payload, :request) || %{}
    operation = fetch(request, :operation) || "tool"
    details = fetch(request, :details)

    summary =
      if is_nil(details) do
        ""
      else
        " details=#{inspect(details, limit: 10)}"
      end

    "Approve #{operation} on #{node_name}?#{summary}"
  end

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch(_map, _key), do: nil

  defp call_prompt(nil, message, opts), do: Codex.prompt(message, opts)
  defp call_prompt(node, message, opts) when is_atom(node), do: Codex.prompt(node, message, opts)

  defp maybe_put_timeout(opts, value) when is_integer(value) and value > 0,
    do: Keyword.put(opts, :timeout, value)

  defp maybe_put_timeout(opts, _), do: opts

  defp maybe_put_stream_target(opts, true, caller_pid),
    do: Keyword.put(opts, :stream_to, caller_pid)

  defp maybe_put_stream_target(opts, _stream, _caller_pid), do: opts

  defp maybe_put_approval(opts, approval_mode, caller_pid) do
    opts
    |> Keyword.put(:approval_mode, approval_mode)
    |> Keyword.put(:approval_to, caller_pid)
  end
end
