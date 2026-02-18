defmodule ElxDockerNode.CodexChatUi do
  @moduledoc false
  use TermUI.Elm

  alias ElxDockerNode.Codex
  alias ElxDockerNode.CodexStream
  alias TermUI.Event
  alias TermUI.Renderer.Style

  @max_entries 600
  @default_width 100
  @default_height 30

  @spec run([node() | nil], keyword(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def run(targets, prompt_opts, first_message \\ nil) when is_list(targets) do
    opts = [
      root: __MODULE__,
      targets: targets,
      prompt_opts: prompt_opts,
      first_message: first_message
    ]

    case TermUI.Runtime.start_link(opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} ->
            {:ok, :exited_normally}

          {:DOWN, ^ref, :process, ^pid, reason} ->
            _ = ensure_terminal_cleanup()
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    targets =
      opts
      |> Keyword.get(:targets, [nil])
      |> normalize_targets()

    prompt_opts = Keyword.get(opts, :prompt_opts, [])
    first_message = Keyword.get(opts, :first_message)

    state = %{
      targets: targets,
      active_index: 0,
      prompt_opts: prompt_opts,
      show_thoughts?: Keyword.get(prompt_opts, :show_thoughts, true),
      show_tools?: Keyword.get(prompt_opts, :show_tools, true),
      input: "",
      entries: [],
      pending_prompt: nil,
      pending_status: false,
      approval_request: nil,
      tool_context: %{},
      stream_indices: %{},
      scroll_offset: 0,
      width: @default_width,
      height: @default_height
    }

    state =
      state
      |> append_entry(:system, "chat", "TermUI chat mode enabled.")
      |> append_entry(
        :system,
        "chat",
        "Commands: /targets, /use <n>, /status, /cancel, /help, /exit"
      )

    if is_binary(first_message) and String.trim(first_message) != "" do
      send(self(), {:chat_bootstrap, first_message})
    end

    state
  end

  @impl true
  def event_to_msg(%Event.Key{key: key}, %{approval_request: request})
      when not is_nil(request) and key in ["y", "Y"] do
    {:msg, {:approval_decision, true}}
  end

  def event_to_msg(%Event.Key{key: key}, %{approval_request: request})
      when not is_nil(request) and key in ["n", "N"] do
    {:msg, {:approval_decision, false}}
  end

  def event_to_msg(%Event.Key{key: key, modifiers: modifiers}, _state)
      when key in ["c", "C"] and is_list(modifiers) do
    if :ctrl in modifiers, do: {:msg, :quit}, else: {:msg, {:insert, key}}
  end

  def event_to_msg(%Event.Key{key: :escape}, _state), do: {:msg, :quit}
  def event_to_msg(%Event.Key{key: :enter}, _state), do: {:msg, :submit}
  def event_to_msg(%Event.Key{key: :backspace}, _state), do: {:msg, :backspace}
  def event_to_msg(%Event.Key{key: :delete}, _state), do: {:msg, :backspace}
  def event_to_msg(%Event.Key{key: :tab}, _state), do: {:msg, :next_target}
  def event_to_msg(%Event.Key{key: :page_up}, _state), do: {:msg, :scroll_up}
  def event_to_msg(%Event.Key{key: :page_down}, _state), do: {:msg, :scroll_down}
  def event_to_msg(%Event.Paste{content: content}, _state), do: {:msg, {:paste, content}}

  def event_to_msg(%Event.Resize{width: width, height: height}, _state) do
    {:msg, {:resize, width, height}}
  end

  def event_to_msg(%Event.Key{key: key, modifiers: []}, _state) when is_binary(key) do
    {:msg, {:insert, key}}
  end

  def event_to_msg(_, _state), do: :ignore

  @impl true
  def update(:quit, state), do: {state, [:quit]}

  def update({:resize, width, height}, state) do
    {
      %{
        state
        | width: max(40, width),
          height: max(10, height)
      },
      []
    }
  end

  def update(:next_target, state) do
    next_index =
      case state.targets do
        [_single] -> state.active_index
        targets -> rem(state.active_index + 1, length(targets))
      end

    {
      state
      |> Map.put(:active_index, next_index)
      |> Map.put(:scroll_offset, 0),
      []
    }
  end

  def update(:scroll_up, state), do: {%{state | scroll_offset: state.scroll_offset + 5}, []}

  def update(:scroll_down, state),
    do: {%{state | scroll_offset: max(0, state.scroll_offset - 5)}, []}

  def update(:backspace, state) do
    {%{state | input: drop_last_grapheme(state.input)}, []}
  end

  def update({:paste, content}, state) do
    normalized =
      content
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")

    {%{state | input: state.input <> normalized}, []}
  end

  def update({:insert, chunk}, state) do
    {%{state | input: state.input <> chunk}, []}
  end

  def update({:approval_decision, decision}, state) do
    {reply_approval(state, decision), []}
  end

  def update(:submit, state) do
    input = String.trim(state.input)
    state = %{state | input: ""}

    cond do
      input == "" ->
        {state, []}

      String.starts_with?(input, "/") ->
        handle_command(state, input)

      state.pending_prompt != nil ->
        {append_entry(state, :system, "chat", "A prompt is already running."), []}

      true ->
        {start_prompt(state, input), []}
    end
  end

  def update(_msg, state), do: {state, []}

  def handle_info({:chat_bootstrap, message}, state) do
    trimmed = String.trim(message)

    if trimmed == "" do
      {state, []}
    else
      {start_prompt(state, trimmed), []}
    end
  end

  def handle_info({:chat_prompt_finished, target, {:ok, result}}, state) do
    label = target_label(target)

    state =
      state
      |> maybe_append_result_chunks(label, result)
      |> append_entry(:status, label, "stop_reason=#{result.stop_reason}")
      |> Map.put(:pending_prompt, nil)
      |> Map.put(:approval_request, nil)
      |> Map.put(:tool_context, %{})
      |> Map.put(:stream_indices, %{})
      |> Map.put(:scroll_offset, 0)

    {state, []}
  end

  def handle_info({:chat_prompt_finished, target, {:error, reason}}, state) do
    label = target_label(target)

    state =
      state
      |> append_entry(:error, label, "Prompt failed: #{inspect(reason)}")
      |> Map.put(:pending_prompt, nil)
      |> Map.put(:approval_request, nil)
      |> Map.put(:tool_context, %{})
      |> Map.put(:stream_indices, %{})
      |> Map.put(:scroll_offset, 0)

    {state, []}
  end

  def handle_info({:chat_status_result, target, result}, state) do
    label = target_label(target)
    state = %{state | pending_status: false}

    state =
      case result do
        {:ok, status} ->
          summary =
            "status=#{status.status} connected=#{status.connected} session_id=#{status.session_id || "-"}"

          append_entry(state, :status, label, summary)

        {:error, reason} ->
          append_entry(state, :error, label, "status failed: #{inspect(reason)}")
      end

    {state, []}
  end

  def handle_info({:chat_cancel_result, target, result}, state) do
    label = target_label(target)

    state =
      case result do
        :ok ->
          append_entry(state, :status, label, "Cancel requested. Waiting for remote agent...")

        {:error, :no_prompt_in_progress} ->
          append_entry(state, :system, label, "No prompt is currently running.")

        {:error, reason} ->
          append_entry(state, :error, label, "Cancel failed: #{inspect(reason)}")
      end

    {state, []}
  end

  def handle_info({:codex_prompt_stream, payload}, state) do
    {handle_stream_payload(payload, state), []}
  end

  def handle_info({:codex_tool_approval_request, payload}, state) do
    request = fetch(payload, :request) || %{}
    operation = fetch(request, :operation) || "tool"
    details = fetch(request, :details)

    line = format_approval_line(operation, details)

    state =
      state
      |> Map.put(:approval_request, payload)
      |> append_entry(:system, "chat", line)
      |> Map.put(:scroll_offset, 0)

    {state, []}
  end

  def handle_info(_msg, state), do: {state, []}

  @impl true
  def view(state) do
    active_target = Enum.at(state.targets, state.active_index)
    active_label = target_label(active_target)

    header_style = Style.new(fg: :cyan, attrs: [:bold])
    meta_style = Style.new(fg: :bright_black)
    input_style = Style.new(fg: :white, attrs: [:bold])
    approval_style = Style.new(fg: :yellow, attrs: [:bold])

    pending =
      if state.pending_prompt do
        "running"
      else
        "idle"
      end

    header =
      "Codex Chat (term_ui) target #{state.active_index + 1}/#{length(state.targets)} #{active_label} | #{pending}"

    subheader =
      "Tab switch target | Enter send | Ctrl+C exit | /help"

    body_height = max(state.height - 6, 6)
    body_width = max(state.width - 2, 20)

    rendered_lines =
      state.entries
      |> entries_to_lines(body_width)
      |> visible_lines(body_height, state.scroll_offset)

    body_nodes =
      if rendered_lines == [] do
        [text("", nil)]
      else
        Enum.map(rendered_lines, fn %{text: line, style: style} ->
          text(line, style)
        end)
      end

    input_line =
      case state.approval_request do
        nil -> "[#{active_label}] you> #{state.input}"
        _payload -> "Approval pending: press y to allow / n to deny"
      end

    input_node_style =
      case state.approval_request do
        nil -> input_style
        _ -> approval_style
      end

    stack(
      :vertical,
      [
        text(header, header_style),
        text(subheader, meta_style),
        text("", nil)
        | body_nodes
      ] ++
        [
          text("", nil),
          text(input_line, input_node_style)
        ]
    )
  end

  defp normalize_targets(targets) do
    targets =
      targets
      |> Enum.map(fn
        nil -> nil
        target when is_atom(target) -> target
      end)
      |> Enum.uniq()

    if targets == [], do: [nil], else: targets
  end

  defp handle_command(state, "/exit"), do: {state, [:quit]}

  defp handle_command(state, "/help") do
    {
      state
      |> append_entry(:system, "chat", "/targets: list available targets")
      |> append_entry(:system, "chat", "/use <n>: switch active target")
      |> append_entry(:system, "chat", "/status: fetch target bridge status")
      |> append_entry(:system, "chat", "/cancel: cancel running prompt")
      |> append_entry(:system, "chat", "/exit: close chat"),
      []
    }
  end

  defp handle_command(state, "/targets") do
    state =
      state
      |> append_entry(:system, "chat", "Available targets:")
      |> append_target_rows()

    {state, []}
  end

  defp handle_command(state, "/status") do
    if state.pending_status do
      {append_entry(state, :system, "chat", "Status request already running."), []}
    else
      target = Enum.at(state.targets, state.active_index)
      label = target_label(target)
      owner = self()

      Task.start(fn ->
        result =
          try do
            Codex.status(target)
          rescue
            error ->
              {:error, {:status_task_error, Exception.message(error)}}
          catch
            kind, reason ->
              {:error, {:status_task_exit, {kind, reason}}}
          end

        send(owner, {:chat_status_result, target, result})
      end)

      {
        state
        |> Map.put(:pending_status, true)
        |> append_entry(:status, label, "Fetching status..."),
        []
      }
    end
  end

  defp handle_command(state, "/cancel") do
    case state.pending_prompt do
      nil ->
        {append_entry(state, :system, "chat", "No prompt is currently running."), []}

      pending ->
        target = pending.target
        label = pending.label
        owner = self()

        Task.start(fn ->
          result =
            try do
              Codex.cancel(target)
            rescue
              error ->
                {:error, {:cancel_task_error, Exception.message(error)}}
            catch
              kind, reason ->
                {:error, {:cancel_task_exit, {kind, reason}}}
            end

          send(owner, {:chat_cancel_result, target, result})
        end)

        {append_entry(state, :status, label, "Cancelling prompt..."), []}
    end
  end

  defp handle_command(state, command) do
    case String.split(command, ~r/\s+/, trim: true) do
      ["/use", raw_index] ->
        switch_target(state, raw_index)

      _ ->
        {append_entry(state, :error, "chat", "Unknown command: #{command}"), []}
    end
  end

  defp switch_target(state, raw_index) do
    case Integer.parse(raw_index) do
      {index, ""} when index > 0 and index <= length(state.targets) ->
        next_index = index - 1
        label = state.targets |> Enum.at(next_index) |> target_label()

        {
          state
          |> Map.put(:active_index, next_index)
          |> Map.put(:scroll_offset, 0)
          |> append_entry(:status, label, "Switched to target #{index}."),
          []
        }

      _ ->
        {append_entry(state, :error, "chat", "Invalid target index: #{raw_index}"), []}
    end
  end

  defp start_prompt(state, message) do
    target = Enum.at(state.targets, state.active_index)
    label = target_label(target)
    owner = self()

    prompt_opts = build_prompt_opts(state.prompt_opts, owner)

    Task.start(fn ->
      result =
        try do
          call_prompt(target, message, prompt_opts)
        rescue
          error ->
            {:error, {:prompt_task_error, Exception.message(error)}}
        catch
          kind, reason ->
            {:error, {:prompt_task_exit, {kind, reason}}}
        end

      send(owner, {:chat_prompt_finished, target, result})
    end)

    state
    |> append_entry(:user, label, message)
    |> Map.put(:pending_prompt, %{
      target: target,
      label: label,
      start_index: length(state.entries)
    })
    |> Map.put(:stream_indices, %{})
    |> Map.put(:tool_context, %{})
    |> Map.put(:approval_request, nil)
    |> Map.put(:scroll_offset, 0)
  end

  defp maybe_append_result_chunks(state, label, result) do
    start_index = get_in(state, [:pending_prompt, :start_index]) || 0

    current_prompt_entries =
      state.entries
      |> Enum.drop(start_index)

    has_assistant_for_label? =
      Enum.any?(current_prompt_entries, fn entry ->
        entry.role == :assistant and entry.node == label
      end)

    state =
      if has_assistant_for_label? do
        state
      else
        Enum.reduce(result.message_chunks || [], state, fn chunk, acc ->
          append_stream_chunk(acc, :assistant, label, chunk)
        end)
      end

    has_thought_for_label? =
      Enum.any?(current_prompt_entries, fn entry ->
        entry.role == :thought and entry.node == label
      end)

    if state.show_thoughts? do
      if has_thought_for_label? do
        state
      else
        Enum.reduce(result.thought_chunks || [], state, fn chunk, acc ->
          append_stream_chunk(acc, :thought, label, chunk)
        end)
      end
    else
      state
    end
  end

  defp build_prompt_opts(prompt_opts, owner) do
    prompt_opts
    |> Keyword.take([:timeout, :approval_mode])
    |> maybe_drop_invalid_timeout()
    |> Keyword.put(:stream_to, owner)
    |> Keyword.put(:approval_to, owner)
  end

  defp maybe_drop_invalid_timeout(opts) do
    case Keyword.get(opts, :timeout) do
      value when is_integer(value) and value > 0 -> opts
      _ -> Keyword.delete(opts, :timeout)
    end
  end

  defp call_prompt(nil, message, opts), do: Codex.prompt(message, opts)

  defp call_prompt(target, message, opts) when is_atom(target),
    do: Codex.prompt(target, message, opts)

  defp format_approval_line(operation, details) do
    case {operation, details} do
      {"session/request_permission", permission_details} when is_map(permission_details) ->
        options =
          permission_details
          |> fetch(:options)
          |> List.wrap()
          |> Enum.map(fn option ->
            option_id = fetch(option, :optionId) || fetch(option, :option_id) || "?"
            option_name = fetch(option, :name) || option_id
            "#{option_name} (#{option_id})"
          end)

        tool_call = fetch(permission_details, :tool_call) || fetch(permission_details, :toolCall)

        tool_label =
          cond do
            is_map(tool_call) and is_binary(fetch(tool_call, :title)) ->
              fetch(tool_call, :title)

            is_map(tool_call) and is_binary(fetch(tool_call, :kind)) ->
              "kind=#{fetch(tool_call, :kind)}"

            true ->
              "remote tool call"
          end

        if options == [] do
          "Approval required for #{tool_label}. Press y/n."
        else
          "Approval required for #{tool_label}: #{Enum.join(options, ", ")} (y/n)"
        end

      {_operation, nil} ->
        "Approval required for #{operation}. Press y/n."

      _ ->
        "Approval required for #{operation}: #{inspect(details, limit: 8)} (y/n)"
    end
  end

  defp reply_approval(state, decision) do
    payload = state.approval_request
    ref = fetch(payload || %{}, :ref)
    reply_to = fetch(payload || %{}, :reply_to)

    if is_reference(ref) and is_pid(reply_to) do
      send(reply_to, {:codex_tool_approval_reply, ref, decision})
    end

    outcome = if decision, do: "Approved tool request.", else: "Denied tool request."

    state
    |> Map.put(:approval_request, nil)
    |> append_entry(:system, "chat", outcome)
  end

  defp handle_stream_payload(payload, state) do
    case fetch(payload, :event) do
      event when event in [:start, "start"] ->
        state

      event when event in [:done, "done"] ->
        %{state | stream_indices: %{}}

      event when event in [:error, "error"] ->
        reason = fetch(payload, :reason)
        append_entry(state, :error, "chat", "Stream error: #{inspect(reason)}")

      event when event in [:status, "status"] ->
        message =
          case fetch(payload, :message) do
            "cancel_requested" -> "Cancel requested. Waiting for remote agent..."
            other when is_binary(other) -> other
            _ -> "Status update received."
          end

        node = fetch(payload, :node) || Node.self()
        append_entry(state, :status, target_label(node), message)

      event when event in [:update, "update"] ->
        update = fetch(payload, :update)
        node = fetch(payload, :node) || Node.self()
        render_stream_update(update, target_label(node), state)

      _ ->
        state
    end
  end

  defp render_stream_update(update, node_label, state) when is_map(update) do
    kind = CodexStream.update_kind(update)

    cond do
      thought_kind?(kind) and state.show_thoughts? ->
        update
        |> CodexStream.thought_chunks()
        |> Enum.reduce(state, fn chunk, acc ->
          append_stream_chunk(acc, :thought, node_label, chunk)
        end)

      message_kind?(kind) ->
        update
        |> CodexStream.message_chunks()
        |> Enum.reduce(state, fn chunk, acc ->
          append_stream_chunk(acc, :assistant, node_label, chunk)
        end)

      tool_kind?(kind) and state.show_tools? ->
        render_tool_update(update, node_label, state)

      true ->
        state
    end
  end

  defp render_stream_update(_update, _node_label, state), do: state

  defp thought_kind?(kind) when is_binary(kind) do
    String.contains?(kind, "thought") or String.contains?(kind, "reason")
  end

  defp thought_kind?(_), do: false

  defp message_kind?(kind) when is_binary(kind) do
    String.contains?(kind, "message") and not String.starts_with?(kind, "user_")
  end

  defp message_kind?(_), do: false

  defp tool_kind?(kind) when is_binary(kind) do
    kind in ["tool_call", "tool_call_update"] or String.contains?(kind, "tool_call")
  end

  defp tool_kind?(_), do: false

  defp render_tool_update(update, node_label, state) do
    tool_context = update_tool_context(state.tool_context, node_label, update)
    enriched_update = tool_context_for(tool_context, node_label, update)
    activity = CodexStream.tool_activity(enriched_update)
    summary = CodexStream.tool_summary(enriched_update)

    state
    |> Map.put(:tool_context, tool_context)
    |> append_entry(:tool, node_label, "#{activity}: #{summary}")
  end

  defp update_tool_context(context, node_label, update) do
    tool_id = CodexStream.tool_call_id(update)

    if is_binary(tool_id) and tool_id != "" do
      key = {node_label, tool_id}
      previous = Map.get(context, key, %{})

      current =
        %{}
        |> put_if_present("toolCallId", tool_id)
        |> put_if_present("title", CodexStream.tool_title(update))
        |> put_if_present("kind", CodexStream.tool_kind(update))
        |> put_if_present("status", CodexStream.tool_status(update))
        |> put_if_present("rawInput", fetch(update, :rawInput) || fetch(update, :raw_input))
        |> put_if_present("content", fetch(update, :content))
        |> put_if_present("locations", fetch(update, :locations))

      Map.put(context, key, Map.merge(previous, current))
    else
      context
    end
  end

  defp tool_context_for(context, node_label, update) do
    tool_id = CodexStream.tool_call_id(update)

    if is_binary(tool_id) and tool_id != "" do
      Map.get(context, {node_label, tool_id}, update)
    else
      update
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, value) when value == "", do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp append_stream_chunk(state, _role, _node, chunk) when not is_binary(chunk) or chunk == "" do
    state
  end

  defp append_stream_chunk(state, role, node, chunk) do
    key = {role, node}
    chunk = normalize_stream_chunk(chunk)

    case Map.fetch(state.stream_indices, key) do
      {:ok, index} ->
        if index < length(state.entries) do
          updated_entries =
            List.update_at(state.entries, index, fn entry ->
              %{entry | text: entry.text <> chunk}
            end)

          %{state | entries: updated_entries, scroll_offset: 0}
        else
          append_fresh_stream_entry(state, key, role, node, chunk)
        end

      :error ->
        append_fresh_stream_entry(state, key, role, node, chunk)
    end
  end

  defp append_fresh_stream_entry(state, key, role, node, chunk) do
    {state, index} = append_entry_with_index(state, %{role: role, node: node, text: chunk})
    %{state | stream_indices: Map.put(state.stream_indices, key, index), scroll_offset: 0}
  end

  defp append_target_rows(state) do
    state.targets
    |> Enum.with_index()
    |> Enum.reduce(state, fn {target, index}, acc ->
      marker = if index == acc.active_index, do: "*", else: " "
      line = "#{marker} #{index + 1}. #{target_label(target)}"
      append_entry(acc, :system, "chat", line)
    end)
  end

  defp entries_to_lines(entries, width) do
    Enum.flat_map(entries, fn entry ->
      style = entry_style(entry.role)
      prefix = entry_prefix(entry)
      padding = String.duplicate(" ", String.length(prefix) + 1)

      entry.text
      |> String.split("\n", trim: false)
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, index} ->
        prefixed =
          if index == 0 do
            "#{prefix} #{line}"
          else
            "#{padding}#{line}"
          end

        wrap_line(prefixed, width)
        |> Enum.map(fn wrapped_line -> %{text: wrapped_line, style: style} end)
      end)
    end)
  end

  defp visible_lines(lines, height, scroll_offset) do
    total = length(lines)
    max_offset = max(total - height, 0)
    offset = min(scroll_offset, max_offset)
    start_index = max(total - height - offset, 0)
    Enum.slice(lines, start_index, height)
  end

  defp wrap_line(line, width) when width <= 0, do: [line]

  defp wrap_line(line, width) do
    if String.length(line) <= width do
      [line]
    else
      {head, tail} = String.split_at(line, width)
      [head | wrap_line(tail, width)]
    end
  end

  defp append_entry(state, role, node, text) do
    {state, _index} = append_entry_with_index(state, %{role: role, node: node, text: text})
    state
  end

  defp append_entry_with_index(state, entry) do
    entries = state.entries ++ [entry]
    overflow = max(length(entries) - @max_entries, 0)
    entries = if overflow > 0, do: Enum.drop(entries, overflow), else: entries
    index = length(entries) - 1

    stream_indices =
      state.stream_indices
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        shifted = value - overflow
        if shifted >= 0, do: Map.put(acc, key, shifted), else: acc
      end)

    {
      %{
        state
        | entries: entries,
          stream_indices: stream_indices,
          scroll_offset: 0
      },
      index
    }
  end

  defp normalize_stream_chunk(chunk) do
    chunk
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp entry_prefix(%{role: :user, node: node}), do: "[#{node}] you>"
  defp entry_prefix(%{role: :assistant, node: node}), do: "[#{node}]"
  defp entry_prefix(%{role: :thought, node: node}), do: "[#{node} thought]"
  defp entry_prefix(%{role: :tool, node: node}), do: "[#{node} tool]"
  defp entry_prefix(%{role: :status, node: node}), do: "[#{node} status]"
  defp entry_prefix(%{role: :system}), do: "[system]"
  defp entry_prefix(%{role: :error}), do: "[error]"

  defp entry_style(:user), do: Style.new(fg: :yellow, attrs: [:bold])
  defp entry_style(:assistant), do: Style.new(fg: :green)
  defp entry_style(:thought), do: Style.new(fg: :magenta)
  defp entry_style(:tool), do: Style.new(fg: :blue)
  defp entry_style(:status), do: Style.new(fg: :cyan)
  defp entry_style(:system), do: Style.new(fg: :bright_black)
  defp entry_style(:error), do: Style.new(fg: :red, attrs: [:bold])

  defp target_label(nil) do
    if Node.alive?(), do: to_string(Node.self()), else: "local"
  end

  defp target_label(node) when is_atom(node), do: to_string(node)

  defp drop_last_grapheme(""), do: ""

  defp drop_last_grapheme(value) do
    value
    |> String.graphemes()
    |> Enum.drop(-1)
    |> Enum.join()
  end

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch(_map, _key), do: nil

  defp ensure_terminal_cleanup do
    IO.write("\e[?1006l\e[?1003l\e[?1002l\e[?1000l")
    IO.write("\e[?25h")
    IO.write("\e[0m")
    IO.write("\e[2J")
    IO.write("\e[H")
    :ok
  rescue
    _ -> :error
  end
end
