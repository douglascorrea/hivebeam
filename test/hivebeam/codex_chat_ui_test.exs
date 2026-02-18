defmodule Hivebeam.CodexChatUiTest do
  use ExUnit.Case, async: true

  alias Hivebeam.CodexChatUi
  alias TermUI.Event

  test "keeps stream order when tool updates interleave with assistant chunks" do
    state =
      CodexChatUi.init(
        targets: [:"codex@192.168.50.234"],
        prompt_opts: [show_thoughts: true, show_tools: true]
      )

    {:ok, state} =
      push_stream_update(
        state,
        %{"type" => "agent_message_chunk", "content" => %{"text" => "first"}}
      )

    {:ok, state} =
      push_stream_update(
        state,
        %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "tool-1",
          "title" => "Read mix.exs",
          "kind" => "read",
          "status" => "in_progress"
        }
      )

    {:ok, state} =
      push_stream_update(
        state,
        %{"type" => "agent_message_chunk", "content" => %{"text" => "second"}}
      )

    last_entries = Enum.take(state.entries, -3)

    assert Enum.map(last_entries, & &1.role) == [:assistant, :activity, :assistant]
    assert Enum.at(last_entries, 0).text == "first"
    assert Enum.at(last_entries, 1).latest_activity == "Exploring"
    assert map_size(Enum.at(last_entries, 1).tool_rows) == 1
    assert Enum.at(last_entries, 2).text == "second"
  end

  test "shows thinking activity card when prompt stream starts" do
    state =
      CodexChatUi.init(
        targets: [:"codex@192.168.50.234"],
        prompt_opts: [show_thoughts: true, show_tools: true]
      )

    {:ok, state} =
      push_stream_event(
        state,
        :start,
        nil
      )

    assert List.last(state.entries) == %{
             role: :activity,
             node: "codex@192.168.50.234",
             running: true,
             latest_activity: "Thinking",
             latest_summary: nil,
             thought_text: "",
             tool_rows: %{},
             tool_order: []
           }
  end

  test "does not duplicate thinking activity cards for repeated start events" do
    state =
      CodexChatUi.init(
        targets: [:"codex@192.168.50.234"],
        prompt_opts: [show_thoughts: true, show_tools: true]
      )

    {:ok, state} = push_stream_event(state, :start, nil)
    {:ok, state} = push_stream_event(state, :start, nil)

    activity_entries =
      Enum.filter(state.entries, fn
        %{role: :activity, node: "codex@192.168.50.234"} -> true
        _ -> false
      end)

    assert length(activity_entries) == 1
  end

  test "preserves scroll position while new output streams when user is scrolled up" do
    state =
      CodexChatUi.init(
        targets: [:"codex@192.168.50.234"],
        prompt_opts: [show_thoughts: true, show_tools: true]
      )

    large_chunk =
      1..40
      |> Enum.map_join("\n", fn n -> "line-#{n}" end)

    {:ok, state} =
      push_stream_update(
        state,
        %{"type" => "agent_message_chunk", "content" => %{"text" => large_chunk}}
      )

    {state, []} = CodexChatUi.update(:scroll_up_page, state)
    assert state.scroll_offset > 0
    assert state.follow_output? == false

    old_offset = state.scroll_offset

    {:ok, state} =
      push_stream_update(
        state,
        %{"type" => "agent_message_chunk", "content" => %{"text" => "\nnew-tail-line"}}
      )

    assert state.scroll_offset > old_offset
    assert state.follow_output? == false

    {state, []} = CodexChatUi.update(:scroll_bottom, state)
    assert state.scroll_offset == 0
    assert state.follow_output? == true
  end

  test "leading %node+agent routes prompt to explicit target" do
    state =
      CodexChatUi.init(
        targets: [
          %{node: :"codex@10.0.0.20", bridge_name: Hivebeam.CodexBridge},
          %{node: :"codex@10.0.0.20", bridge_name: Hivebeam.ClaudeBridge}
        ],
        target_aliases: %{"codex@10.0.0.20" => "box1"}
      )

    {state, []} = CodexChatUi.update({:insert, "%box1+claude ping"}, state)
    {state, []} = CodexChatUi.update(:submit, state)

    assert state.pending_prompt != nil
    assert state.pending_prompt.target.node_alias == "box1"
    assert state.pending_prompt.target.provider_alias == "claude"

    drain_prompt_messages()
  end

  test "invalid routed target appends chat error and does not start prompt" do
    state =
      CodexChatUi.init(
        targets: [%{node: :"codex@10.0.0.20", bridge_name: Hivebeam.CodexBridge}],
        target_aliases: %{"codex@10.0.0.20" => "box1"}
      )

    {state, []} = CodexChatUi.update({:insert, "%missing+claude ping"}, state)
    {state, []} = CodexChatUi.update(:submit, state)

    assert state.pending_prompt == nil
    assert List.last(state.entries).role == :error
  end

  test "plain prompt uses active target" do
    state =
      CodexChatUi.init(
        targets: [
          %{node: :"codex@10.0.0.20", bridge_name: Hivebeam.CodexBridge},
          %{node: :"codex@10.0.0.20", bridge_name: Hivebeam.ClaudeBridge}
        ],
        target_aliases: %{"codex@10.0.0.20" => "box1"}
      )

    state = %{state | active_index: 1}

    {state, []} = CodexChatUi.update({:insert, "hello"}, state)
    {state, []} = CodexChatUi.update(:submit, state)

    assert state.pending_prompt != nil
    assert state.pending_prompt.target.provider_alias == "claude"

    drain_prompt_messages()
  end

  test "tab autocompletes %target mentions and cycles on repeated tab" do
    state =
      CodexChatUi.init(
        targets: [
          %{node: :"codex@10.0.0.20", bridge_name: Hivebeam.CodexBridge},
          %{node: :"codex@10.0.0.20", bridge_name: Hivebeam.ClaudeBridge}
        ],
        target_aliases: %{"codex@10.0.0.20" => "box1"}
      )

    {state, []} = CodexChatUi.update({:insert, "%box1+"}, state)
    {state, []} = CodexChatUi.update(:tab_pressed, state)
    first = state.input

    {state, []} = CodexChatUi.update(:tab_pressed, state)
    second = state.input

    assert String.starts_with?(first, "%box1+")
    assert String.starts_with?(second, "%box1+")
    refute first == second
  end

  test "tab autocompletes @file paths for active target context" do
    state = CodexChatUi.init(targets: [nil])

    {state, []} = CodexChatUi.update({:insert, "@li"}, state)
    {state, []} = CodexChatUi.update(:tab_pressed, state)

    assert state.input == "@lib/"
  end

  test "tab autocompletes @file paths using routed %node+provider target" do
    state =
      CodexChatUi.init(
        targets: [
          %{node: nil, bridge_name: Hivebeam.CodexBridge},
          %{node: :"codex@10.0.0.99", bridge_name: Hivebeam.CodexBridge}
        ]
      )

    state = %{state | active_index: 1}

    {state, []} = CodexChatUi.update({:insert, "%node1+codex @li"}, state)
    {state, []} = CodexChatUi.update(:tab_pressed, state)

    assert state.input == "%node1+codex @lib/"
  end

  test "ignores ctrl+o keybinding" do
    assert :ignore == CodexChatUi.event_to_msg(%Event.Key{key: "o", modifiers: [:ctrl]}, %{})
  end

  test "initial layout uses terminal dimensions with minimum bounds" do
    state = CodexChatUi.init(targets: [nil])
    assert state.width >= 40
    assert state.height >= 10
  end

  defp push_stream_update(state, update) do
    push_stream_event(state, :update, update)
  end

  defp push_stream_event(state, event, update) do
    payload =
      %{event: event, node: :"codex@192.168.50.234"}
      |> maybe_put_update(update)

    case CodexChatUi.handle_info({:codex_prompt_stream, payload}, state) do
      {next_state, []} -> {:ok, next_state}
      other -> {:error, other}
    end
  end

  defp maybe_put_update(payload, nil), do: payload
  defp maybe_put_update(payload, update), do: Map.put(payload, :update, update)

  defp drain_prompt_messages do
    receive do
      {:chat_prompt_finished, _target, _result} ->
        drain_prompt_messages()
    after
      0 ->
        :ok
    end
  end
end
