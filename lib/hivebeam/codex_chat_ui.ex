defmodule Hivebeam.CodexChatUi do
  @moduledoc false
  use TermUI.Elm

  alias Hivebeam.Codex
  alias Hivebeam.CodexStream
  alias TermUI.Event
  alias TermUI.Renderer.Style

  @default_width 100
  @default_height 30

  @scroll_step 3
  @running_gradient [
    {18, 52, 76},
    {20, 58, 84},
    {22, 64, 92},
    {24, 70, 100},
    {22, 64, 92},
    {20, 58, 84}
  ]
  @spinner_frames ["-", "\\", "|", "/"]
  @animation_interval_ms 120

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
      activity_indices: %{},
      expanded_entries: MapSet.new(),
      last_expandable_index: nil,
      follow_output?: true,
      scroll_offset: 0,
      animation_phase: 0,
      animation_timer_ref: schedule_animation_tick(),
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
      when key in ["o", "O"] and is_list(modifiers) do
    if :ctrl in modifiers, do: {:msg, :toggle_activity_expand}, else: {:msg, {:insert, key}}
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
  def event_to_msg(%Event.Key{key: :up}, _state), do: {:msg, :scroll_up_line}
  def event_to_msg(%Event.Key{key: :down}, _state), do: {:msg, :scroll_down_line}
  def event_to_msg(%Event.Key{key: :page_up}, _state), do: {:msg, :scroll_up_page}
  def event_to_msg(%Event.Key{key: :page_down}, _state), do: {:msg, :scroll_down_page}
  def event_to_msg(%Event.Key{key: :home}, _state), do: {:msg, :scroll_top}
  def event_to_msg(%Event.Key{key: :end}, _state), do: {:msg, :scroll_bottom}
  def event_to_msg(%Event.Mouse{action: :scroll_up}, _state), do: {:msg, :scroll_up_line}
  def event_to_msg(%Event.Mouse{action: :scroll_down}, _state), do: {:msg, :scroll_down_line}
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
    state =
      %{
        state
        | width: max(40, width),
          height: max(10, height)
      }
      |> normalize_scroll_after_layout_change()

    {state, []}
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
      |> scroll_to_bottom(),
      []
    }
  end

  def update(:scroll_up_line, state), do: {scroll_by(state, 1), []}
  def update(:scroll_down_line, state), do: {scroll_by(state, -1), []}
  def update(:scroll_up_page, state), do: {scroll_by(state, page_step(state)), []}
  def update(:scroll_down_page, state), do: {scroll_by(state, -page_step(state)), []}
  def update(:scroll_top, state), do: {scroll_to_top(state), []}
  def update(:scroll_bottom, state), do: {scroll_to_bottom(state), []}

  def update(:toggle_activity_expand, state) do
    index = latest_expandable_index(state)

    state =
      cond do
        is_nil(index) ->
          state

        MapSet.member?(state.expanded_entries, index) ->
          %{state | expanded_entries: MapSet.delete(state.expanded_entries, index)}

        true ->
          %{state | expanded_entries: MapSet.put(state.expanded_entries, index)}
      end
      |> normalize_scroll_after_layout_change()

    {state, []}
  end

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
      |> finish_activity_for_label(label)
      |> append_entry(:status, label, "stop_reason=#{result.stop_reason}")
      |> Map.put(:pending_prompt, nil)
      |> Map.put(:approval_request, nil)
      |> Map.put(:tool_context, %{})
      |> Map.put(:stream_indices, %{})

    {state, []}
  end

  def handle_info({:chat_prompt_finished, target, {:error, reason}}, state) do
    label = target_label(target)

    state =
      state
      |> finish_activity_for_label(label)
      |> append_entry(:error, label, "Prompt failed: #{inspect(reason)}")
      |> Map.put(:pending_prompt, nil)
      |> Map.put(:approval_request, nil)
      |> Map.put(:tool_context, %{})
      |> Map.put(:stream_indices, %{})

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

    {state, []}
  end

  def handle_info(:chat_animation_tick, state) do
    next_ref = schedule_animation_tick()

    next_phase =
      if map_size(state.activity_indices) > 0 do
        rem(state.animation_phase + 1, 10_000)
      else
        state.animation_phase
      end

    {
      %{state | animation_phase: next_phase, animation_timer_ref: next_ref},
      []
    }
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

    pending = if(state.pending_prompt, do: "running", else: "idle")

    scroll_hint = "scroll #{state.scroll_offset}/#{max_scroll_offset(state)}"

    header =
      "Codex Chat (term_ui) target #{state.active_index + 1}/#{length(state.targets)} #{active_label} | #{pending} | #{scroll_hint}"

    subheader =
      "Tab target | Enter send | Ctrl+O expand activity | Up/Down/Page/Home/End scroll | Ctrl+C exit"

    body_height = body_height(state)
    body_width = body_width(state)

    rendered_lines =
      state.entries
      |> entries_to_lines(body_width, state)
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
      |> append_entry(:system, "chat", "/exit: close chat")
      |> append_entry(:system, "chat", "Ctrl+O: expand/collapse latest activity card")
      |> append_entry(:system, "chat", "Up/Down/PageUp/PageDown/Home/End: scroll transcript"),
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
          |> scroll_to_bottom()
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

    start_index = length(state.entries)

    state
    |> scroll_to_bottom()
    |> append_entry(:user, label, message)
    |> Map.put(:pending_prompt, %{
      target: target,
      label: label,
      start_index: start_index
    })
    |> Map.put(:stream_indices, %{})
    |> Map.put(:tool_context, %{})
    |> Map.put(:activity_indices, %{})
    |> Map.put(:approval_request, nil)
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
      Enum.any?(current_prompt_entries, fn
        %{role: :activity, node: ^label, thought_text: text} when is_binary(text) ->
          String.trim(text) != ""

        _ ->
          false
      end)

    if state.show_thoughts? and not has_thought_for_label? do
      Enum.reduce(result.thought_chunks || [], state, fn chunk, acc ->
        append_activity_thought(acc, label, chunk)
      end)
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
        node = fetch(payload, :node) || Node.self()
        start_activity(state, target_label(node))

      event when event in [:done, "done"] ->
        node = fetch(payload, :node) || Node.self()

        state
        |> finish_activity_for_label(target_label(node))
        |> Map.put(:stream_indices, %{})

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
          append_activity_thought(acc, node_label, chunk)
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
    |> append_activity_tool(node_label, enriched_update, activity, summary)
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

  defp append_activity_thought(state, _node_label, chunk)
       when not is_binary(chunk) or chunk == "" do
    state
  end

  defp append_activity_thought(state, node_label, chunk) do
    chunk = normalize_stream_chunk(chunk)

    state
    |> ensure_activity_entry(node_label)
    |> then(fn {state, index} ->
      update_activity_entry(state, index, fn entry ->
        thought_text = (entry.thought_text || "") <> chunk

        entry
        |> Map.put(:running, true)
        |> Map.put(:latest_activity, "Thinking")
        |> Map.put(:thought_text, thought_text)
      end)
    end)
  end

  defp append_activity_tool(state, node_label, update, activity, summary) do
    tool_key =
      CodexStream.tool_call_id(update) ||
        [activity, summary]
        |> Enum.join("|")

    status = CodexStream.tool_status(update)

    state
    |> ensure_activity_entry(node_label)
    |> then(fn {state, index} ->
      update_activity_entry(state, index, fn entry ->
        tool_rows =
          Map.put(entry.tool_rows || %{}, tool_key, %{
            activity: activity,
            summary: summary,
            status: status
          })

        tool_order =
          if tool_key in (entry.tool_order || []) do
            entry.tool_order
          else
            (entry.tool_order || []) ++ [tool_key]
          end

        entry
        |> Map.put(:running, true)
        |> Map.put(:latest_activity, activity)
        |> Map.put(:latest_summary, summary)
        |> Map.put(:tool_rows, tool_rows)
        |> Map.put(:tool_order, tool_order)
      end)
    end)
  end

  defp start_activity(state, node_label) do
    state
    |> ensure_activity_entry(node_label)
    |> then(fn {state, index} ->
      update_activity_entry(state, index, fn entry ->
        entry
        |> Map.put(:running, true)
        |> Map.put(:latest_activity, entry.latest_activity || "Thinking")
      end)
    end)
  end

  defp finish_activity_for_label(state, node_label) do
    case Map.pop(state.activity_indices, node_label) do
      {nil, _remaining} ->
        state

      {index, remaining} ->
        state = %{state | activity_indices: remaining}

        case update_entry(state, index, fn entry -> Map.put(entry, :running, false) end) do
          {:ok, next_state} -> next_state
          :error -> state
        end
    end
  end

  defp ensure_activity_entry(state, node_label) do
    case Map.fetch(state.activity_indices, node_label) do
      {:ok, index} ->
        if index < length(state.entries) and
             match?(%{role: :activity}, Enum.at(state.entries, index)) do
          {state, index}
        else
          create_activity_entry(state, node_label)
        end

      :error ->
        create_activity_entry(state, node_label)
    end
  end

  defp create_activity_entry(state, node_label) do
    entry = %{
      role: :activity,
      node: node_label,
      running: true,
      latest_activity: "Thinking",
      latest_summary: nil,
      thought_text: "",
      tool_rows: %{},
      tool_order: []
    }

    {state, index} = append_entry_with_index(state, entry)

    {
      %{
        state
        | activity_indices: Map.put(state.activity_indices, node_label, index),
          last_expandable_index: index
      },
      index
    }
  end

  defp update_activity_entry(state, index, updater) do
    case update_entry(state, index, updater) do
      {:ok, state} ->
        %{state | last_expandable_index: index}

      :error ->
        state
    end
  end

  defp append_stream_chunk(state, _role, _node, chunk) when not is_binary(chunk) or chunk == "" do
    state
  end

  defp append_stream_chunk(state, role, node, chunk) do
    key = {role, node}
    chunk = normalize_stream_chunk(chunk)

    case Map.fetch(state.stream_indices, key) do
      {:ok, index} ->
        if index == length(state.entries) - 1 do
          case update_entry(state, index, fn entry -> %{entry | text: entry.text <> chunk} end) do
            {:ok, next_state} -> next_state
            :error -> append_fresh_stream_entry(state, key, role, node, chunk)
          end
        else
          append_fresh_stream_entry(state, key, role, node, chunk)
        end

      :error ->
        append_fresh_stream_entry(state, key, role, node, chunk)
    end
  end

  defp append_fresh_stream_entry(state, key, role, node, chunk) do
    {state, index} = append_entry_with_index(state, %{role: role, node: node, text: chunk})
    %{state | stream_indices: Map.put(state.stream_indices, key, index)}
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

  defp entries_to_lines(entries, width, state) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      separator = if index == 0, do: [], else: [%{text: String.duplicate(" ", width), style: nil}]
      separator ++ entry_to_lines(entry, index, width, state)
    end)
  end

  defp entry_to_lines(%{role: :activity} = entry, index, width, state) do
    entry
    |> activity_lines(MapSet.member?(state.expanded_entries, index), state)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{line, kind}, line_index} ->
      line
      |> wrap_line(width)
      |> Enum.with_index()
      |> Enum.map(fn {segment, segment_index} ->
        style =
          activity_line_style(entry, kind, line_index + segment_index, state.animation_phase)

        %{text: fit_line_width(segment, width), style: style}
      end)
    end)
  end

  defp entry_to_lines(entry, _index, width, _state) do
    style = entry_style(entry.role)
    prefix = entry_prefix(entry)
    padding = String.duplicate(" ", String.length(prefix) + 1)

    entry.text
    |> String.split("\n", trim: false)
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, line_index} ->
      prefixed = if line_index == 0, do: "#{prefix} #{line}", else: "#{padding}#{line}"

      prefixed
      |> wrap_line(width)
      |> Enum.map(fn wrapped_line ->
        %{text: fit_line_width(wrapped_line, width), style: style}
      end)
    end)
  end

  defp activity_lines(entry, expanded?, state) do
    hint = if expanded?, do: "Ctrl+O to collapse", else: "Ctrl+O to expand"
    spinner = if entry.running, do: spinner_frame(state.animation_phase), else: "*"
    summary = activity_summary(entry, hint)

    header = "[#{entry.node} activity] #{spinner} #{summary}"

    lines = [{header, :header}]

    if expanded? do
      lines
      |> maybe_append_thought_lines(entry)
      |> maybe_append_tool_lines(entry)
      |> maybe_append_empty_details(entry)
    else
      lines
    end
  end

  defp maybe_append_thought_lines(lines, %{thought_text: text}) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      lines
    else
      thought_lines =
        trimmed
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&{"  · #{&1}", :detail})

      lines ++ [{"  Thoughts:", :meta}] ++ thought_lines
    end
  end

  defp maybe_append_thought_lines(lines, _entry), do: lines

  defp maybe_append_tool_lines(lines, %{tool_order: order, tool_rows: rows})
       when is_list(order) and is_map(rows) do
    tool_lines =
      order
      |> Enum.map(&Map.get(rows, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn row ->
        status =
          case row.status do
            value when is_binary(value) and value != "" -> " status=#{value}"
            _ -> ""
          end

        {"  - #{row.activity}: #{row.summary}#{status}", :detail}
      end)

    if tool_lines == [] do
      lines
    else
      lines ++ [{"  Tools:", :meta}] ++ tool_lines
    end
  end

  defp maybe_append_tool_lines(lines, _entry), do: lines

  defp maybe_append_empty_details(lines, entry) do
    has_tools? = is_map(entry.tool_rows) and map_size(entry.tool_rows) > 0
    has_thoughts? = is_binary(entry.thought_text) and String.trim(entry.thought_text) != ""

    if has_tools? or has_thoughts? do
      lines
    else
      lines ++ [{"  (no details captured)", :meta}]
    end
  end

  defp activity_summary(entry, hint) do
    tool_count = if is_map(entry.tool_rows), do: map_size(entry.tool_rows), else: 0

    cond do
      entry.running and tool_count > 0 ->
        "#{entry.latest_activity || "Working"} (#{tool_count} tool#{plural(tool_count)} running, #{hint})"

      entry.running ->
        "Thinking... (#{hint})"

      tool_count > 0 ->
        "Used #{tool_count} tool#{plural(tool_count)} (#{hint})"

      true ->
        "Completed (#{hint})"
    end
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp activity_line_style(entry, kind, line_index, animation_phase) do
    if entry.running do
      {r, g, b} = gradient_color(animation_phase + line_index)

      base =
        case kind do
          :header -> Style.new(fg: {210, 242, 255}, bg: {r, g, b}, attrs: [:bold])
          :meta -> Style.new(fg: {170, 214, 236}, bg: {r, g, b})
          :detail -> Style.new(fg: {196, 233, 251}, bg: {r, g, b})
        end

      base
    else
      case kind do
        :header -> Style.new(fg: {188, 226, 244}, bg: {14, 38, 54}, attrs: [:bold])
        :meta -> Style.new(fg: {146, 190, 214}, bg: {14, 38, 54})
        :detail -> Style.new(fg: {178, 214, 234}, bg: {14, 38, 54})
      end
    end
  end

  defp gradient_color(step) do
    Enum.at(@running_gradient, rem(step, length(@running_gradient)))
  end

  defp spinner_frame(phase) do
    Enum.at(@spinner_frames, rem(phase, length(@spinner_frames)))
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

  defp fit_line_width(line, width) do
    line
    |> String.slice(0, width)
    |> String.pad_trailing(width)
  end

  defp append_entry(state, role, node, text) do
    {state, _index} = append_entry_with_index(state, %{role: role, node: node, text: text})
    state
  end

  defp append_entry_with_index(state, entry) do
    old_entries = state.entries
    new_entries = old_entries ++ [entry]
    index = length(new_entries) - 1

    {
      put_entries_with_scroll_adjustment(state, old_entries, new_entries),
      index
    }
  end

  defp update_entry(state, index, updater) when is_integer(index) and index >= 0 do
    if index < length(state.entries) do
      old_entries = state.entries
      new_entries = List.update_at(old_entries, index, updater)
      {:ok, put_entries_with_scroll_adjustment(state, old_entries, new_entries)}
    else
      :error
    end
  end

  defp put_entries_with_scroll_adjustment(state, old_entries, new_entries) do
    if state.follow_output? do
      %{state | entries: new_entries, scroll_offset: 0}
    else
      width = body_width(state)
      before = rendered_line_count(old_entries, width, state)
      after_count = rendered_line_count(new_entries, width, state)
      delta = after_count - before
      max_offset = max(after_count - body_height(state), 0)
      offset = clamp(state.scroll_offset + delta, 0, max_offset)

      %{state | entries: new_entries, scroll_offset: offset, follow_output?: offset == 0}
    end
  end

  defp normalize_stream_chunk(chunk) do
    chunk
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp body_height(state), do: max(state.height - 6, 6)
  defp body_width(state), do: max(state.width - 2, 20)

  defp rendered_line_count(entries, width, state) do
    entries
    |> entries_to_lines(width, state)
    |> length()
  end

  defp max_scroll_offset(state) do
    total = rendered_line_count(state.entries, body_width(state), state)
    max(total - body_height(state), 0)
  end

  defp scroll_by(state, delta) do
    max_offset = max_scroll_offset(state)
    offset = clamp(state.scroll_offset + delta, 0, max_offset)
    %{state | scroll_offset: offset, follow_output?: offset == 0}
  end

  defp scroll_to_top(state) do
    offset = max_scroll_offset(state)
    %{state | scroll_offset: offset, follow_output?: false}
  end

  defp scroll_to_bottom(state) do
    %{state | scroll_offset: 0, follow_output?: true}
  end

  defp normalize_scroll_after_layout_change(state) do
    max_offset = max_scroll_offset(state)

    offset =
      if state.follow_output? do
        0
      else
        min(state.scroll_offset, max_offset)
      end

    %{state | scroll_offset: offset, follow_output?: offset == 0}
  end

  defp page_step(state) do
    max(div(body_height(state), 2), @scroll_step)
  end

  defp latest_expandable_index(state) do
    running_index =
      state.activity_indices
      |> Map.values()
      |> Enum.max(fn -> nil end)

    running_index || state.last_expandable_index
  end

  defp schedule_animation_tick do
    Process.send_after(self(), :chat_animation_tick, @animation_interval_ms)
  end

  defp clamp(value, min_value, max_value) do
    value
    |> max(min_value)
    |> min(max_value)
  end

  defp entry_prefix(%{role: :user, node: node}), do: "[#{node}] you>"
  defp entry_prefix(%{role: :assistant, node: node}), do: "[#{node}] agent>"
  defp entry_prefix(%{role: :thought, node: node}), do: "[#{node} thought]"
  defp entry_prefix(%{role: :tool, node: node}), do: "[#{node} tool]"
  defp entry_prefix(%{role: :status, node: node}), do: "[#{node} status]"
  defp entry_prefix(%{role: :system}), do: "[system]"
  defp entry_prefix(%{role: :error}), do: "[error]"

  defp entry_style(:user), do: Style.new(fg: {226, 241, 255}, bg: {34, 56, 88}, attrs: [:bold])
  defp entry_style(:assistant), do: Style.new(fg: {214, 245, 230}, bg: {10, 35, 43})
  defp entry_style(:thought), do: Style.new(fg: :magenta)
  defp entry_style(:tool), do: Style.new(fg: :blue)
  defp entry_style(:status), do: Style.new(fg: :cyan)
  defp entry_style(:system), do: Style.new(fg: :bright_black)
  defp entry_style(:error), do: Style.new(fg: {255, 192, 192}, bg: {66, 20, 20}, attrs: [:bold])

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
